--!strict
-- One authenticated WebSocket to the local broker.
--
-- Nothing but a hello is sent until the listener has proved it holds the key, and no
-- request is accepted until this side has proved the same. A listener that fails the
-- proof is treated as a foreign program.

local HttpService = game:GetService("HttpService")

local Auth = require("./Auth")
local Codec = require("./Codec")
local Errors = require("./Errors")

export type Credential = { id: string, keyHex: string }
export type SessionInfo = { id: string, placeName: string, placeId: number, pluginVersion: string }
export type State = "connecting" | "ready" | "unpaired" | "denied" | "foreign" | "disconnected" | "stopped"

export type Config = {
	port: number,
	session: SessionInfo,
	credential: Credential?,
	pairingCode: string?,
	onRequest: (method: string, params: any) -> any,
	onState: (state: State, detail: string?) -> (),
	onCredential: (credential: Credential?) -> (),
}

local Connection = {}

local HANDSHAKE_TIMEOUT = 5
local BACKOFF = { 0.5, 1, 2, 4, 5 }
local FOREIGN_RETRY = 30
local PAIRING_RETRY = 2

function Connection.start(config: Config)
	local running = true
	local generation = 0
	local attempts = 0
	local client: any = nil
	local signals: { RBXScriptConnection } = {}
	local queue: { { id: string, method: string, params: any } } = {}
	local working = false
	local stats = { opened = 0, closed = 0, errors = 0, lastError = "" }

	local connect: () -> ()

	local function drop()
		for _, signal in signals do
			signal:Disconnect()
		end
		table.clear(signals)
		if client then
			pcall(function()
				client:Close()
			end)
			client = nil
		end
	end

	local function retry(delaySeconds: number)
		local expected = generation
		task.delay(delaySeconds, function()
			if running and generation == expected then
				connect()
			end
		end)
	end

	local function send(message: any)
		if client then
			client:Send(HttpService:JSONEncode(message))
		end
	end

	-- Requests run one at a time, in arrival order.
	local function drain(expected: number)
		if working then
			return
		end
		working = true
		while running and generation == expected and #queue > 0 do
			local request = table.remove(queue, 1) :: { id: string, method: string, params: any }
			local ok, result = pcall(config.onRequest, request.method, request.params)
			if generation ~= expected then
				break
			end
			if ok then
				send({ t = "res", id = request.id, ok = true, result = result })
			else
				send({ t = "res", id = request.id, ok = false, error = Errors.from(result) })
			end
		end
		working = false
	end

	connect = function()
		drop()
		generation += 1
		local expected = generation
		table.clear(queue)

		local keyName: string
		local key: buffer
		local pairing = false
		if config.credential then
			keyName = "cred:" .. config.credential.id
			key = Codec.fromHex(config.credential.keyHex)
		elseif config.pairingCode then
			keyName = "pair"
			key = Auth.pairingKey(config.pairingCode)
			pairing = true
		else
			config.onState("unpaired")
			return
		end

		local clientNonce = Auth.nonceFromGuid(HttpService:GenerateGUID(false))
		local serverNonce: string? = nil
		local phase = "hello"
		config.onState("connecting")

		local created, result = pcall(function()
			return HttpService:CreateWebStreamClient(Enum.WebStreamClientType.WebSocket, {
				Url = `ws://127.0.0.1:{config.port}/v1`,
				Method = "GET",
			})
		end)
		if not created then
			stats.errors += 1
			stats.lastError = tostring(result)
			config.onState("disconnected", tostring(result))
			attempts += 1
			retry(BACKOFF[math.min(attempts, #BACKOFF)])
			return
		end
		client = result

		local function fail(state: State, detail: string, delaySeconds: number?)
			if generation ~= expected then
				return
			end
			drop()
			config.onState(state, detail)
			if delaySeconds then
				retry(delaySeconds)
			end
		end

		task.delay(HANDSHAKE_TIMEOUT, function()
			if generation == expected and phase ~= "ready" and client then
				attempts += 1
				fail("disconnected", "handshake timed out", BACKOFF[math.min(attempts, #BACKOFF)])
			end
		end)

		table.insert(
			signals,
			client.Opened:Connect(function()
				if generation ~= expected then
					return
				end
				stats.opened += 1
				send({ t = "hello", v = Auth.PROTOCOL_VERSION, role = "plugin", key = keyName, nonce = clientNonce })
			end)
		)

		table.insert(
			signals,
			client.MessageReceived:Connect(function(text: string)
				if generation ~= expected then
					return
				end
				local decoded, message = pcall(function()
					return HttpService:JSONDecode(text)
				end)
				if not decoded or type(message) ~= "table" then
					return fail("foreign", "listener sent something that is not JSON", FOREIGN_RETRY)
				end

				if phase ~= "ready" and message.t == "denied" then
					local code = tostring(message.code)
					if code == "unknown_credential" then
						config.credential = nil
						config.onCredential(nil)
						return fail("unpaired", "the broker no longer knows this credential")
					elseif code == "no_pairing" then
						-- The broker has no code pending, so the person has not registered this
						-- one yet. Keep it and ask again; with nothing pending, asking cannot
						-- count as a failed attempt against any code.
						return fail("unpaired", "waiting for the pairing code to be registered", PAIRING_RETRY)
					end
					return fail("denied", code)
				end

				if phase == "hello" then
					if
						message.t ~= "challenge"
						or type(message.nonce) ~= "string"
						or type(message.proof) ~= "string"
						or #message.nonce ~= 32
					then
						return fail("foreign", "listener sent no valid challenge", FOREIGN_RETRY)
					end
					local expectedProof =
						Auth.hmacHex(key, Auth.proofInput("broker", "plugin", clientNonce, message.nonce))
					if not Auth.equalHex(message.proof, expectedProof) then
						return fail("foreign", "listener failed to prove it is the broker", FOREIGN_RETRY)
					end
					serverNonce = message.nonce
					phase = "auth"
					send({
						t = "auth",
						proof = Auth.hmacHex(key, Auth.proofInput("client", "plugin", clientNonce, message.nonce)),
					})
				elseif phase == "auth" then
					if message.t ~= "ready" then
						return fail("foreign", "listener sent no ready message", FOREIGN_RETRY)
					end
					if pairing then
						if type(message.credential) ~= "string" then
							return fail("denied", "pairing returned no credential")
						end
						local credential = {
							id = message.credential,
							keyHex = Auth.deriveCredentialKeyHex(key, clientNonce, serverNonce :: string),
						}
						config.credential = credential
						config.pairingCode = nil
						config.onCredential(credential)
					end
					phase = "ready"
					attempts = 0
					send({ t = "session", session = config.session })
					config.onState("ready")
				elseif message.t == "req" and type(message.id) == "string" and type(message.method) == "string" then
					table.insert(queue, { id = message.id, method = message.method, params = message.params })
					task.spawn(drain, expected)
				end
			end)
		)

		local function lost(detail: string)
			if generation ~= expected then
				return
			end
			attempts += 1
			fail("disconnected", detail, BACKOFF[math.min(attempts, #BACKOFF)])
		end
		table.insert(
			signals,
			client.Closed:Connect(function()
				stats.closed += 1
				lost("connection closed")
			end)
		)
		table.insert(
			signals,
			client.Error:Connect(function(status: number, message: string)
				stats.errors += 1
				stats.lastError = `{status} {message}`
				lost(`connection error {status} {message}`)
			end)
		)
	end

	connect()

	return {
		stats = stats,
		-- Reconnects with the current credential or pairing code, for example after pairing input.
		reconnect = function()
			if running then
				attempts = 0
				connect()
			end
		end,
		stop = function()
			running = false
			generation += 1
			drop()
			config.onState("stopped")
		end,
	}
end

return Connection
