--!strict
-- Offline tests for the plugin's connection to the broker.
-- Run with: lune run plugin/test/network/connection.test.luau
--
-- Real here: the handshake arithmetic (the same Auth module both sides are checked
-- against), the order of messages, and the request queue. In place of Studio: a socket
-- whose other end the test plays, timers the test fires by hand, and a clock it moves.
-- Not tested here: Studio's own WebSocket client.

local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local Auth = require("../../src/Network/Auth")
local Codec = require("../../src/Core/Codec")
local Connection = require("../../src/Network/Connection")

local failures = 0
local count = 0
local current = ""

local function check(name: string, condition: any, detail: any?)
	count += 1
	if not condition then
		failures += 1
		print(`FAIL [{current}] {name}{if detail ~= nil then ": " .. tostring(detail) else ""}`)
	end
end

local function case(name: string, run: () -> ())
	current = name
	local ok, problem = pcall(run)
	if not ok then
		count += 1
		failures += 1
		print(
			`FAIL [{name}] raised: {if type(problem) == "table" then (problem :: any).message else tostring(problem)}`
		)
	end
end

local function signal()
	local handlers: { [any]: (...any) -> () } = {}
	return {
		Connect = function(_self: any, handler: (...any) -> ())
			local key = {}
			handlers[key] = handler
			return {
				Disconnect = function()
					handlers[key] = nil
				end,
			}
		end,
		fire = function(...: any)
			for _, handler in table.clone(handlers) do
				handler(...)
			end
		end,
	}
end

local KEY_HEX = string.rep("ab", 32)
local GUID = "0123456789abcdef0123456789abcdef"
local SERVER_NONCE = string.rep("5", 32)
local SESSION = { id = "s1", placeName = "Place", placeId = 7, pluginVersion = "0" }

-- A connection whose far end the test plays. `world.sent` is every message the plugin
-- sent, decoded; `world.timers` every timer it set.
local function start(options: { credential: any?, pairingCode: string?, handler: any? })
	local world: any = { sent = {}, timers = {}, states = {}, credentials = {}, cancels = {}, sockets = {}, now = 0 }
	Connection.platform = {
		open = function(port: number)
			local socket: any = {
				Opened = signal(),
				MessageReceived = signal(),
				Closed = signal(),
				Error = signal(),
				port = port,
				closed = false,
			}
			socket.Send = function(_self: any, text: string)
				table.insert(world.sent, serde.decode("json", text))
			end
			socket.Close = function()
				socket.closed = true
			end
			table.insert(world.sockets, socket)
			world.socket = socket
			return socket
		end,
		encode = function(value: any): string
			return serde.encode("json", value)
		end,
		decode = function(text: string): any
			return serde.decode("json", text)
		end,
		guid = function(): string
			return GUID
		end,
		delay = function(seconds: number, work: () -> ())
			table.insert(world.timers, { seconds = seconds, work = work })
		end,
		spawn = task.spawn :: any,
		-- A clock that moves a second every time anyone waits on it.
		kit = {
			spawn = task.spawn :: any,
			wait = function()
				world.now += 1
				task.wait()
			end,
			clock = function(): number
				return world.now
			end,
		},
	}
	world.config = {
		port = 47318,
		session = SESSION,
		credential = options.credential,
		pairingCode = options.pairingCode,
		onRequest = options.handler or function(method: string, params: any)
			return { echoed = method, params = params }
		end,
		onCancel = function(reason: string)
			table.insert(world.cancels, reason)
		end,
		onState = function(state: string, detail: string?)
			table.insert(world.states, state)
			world.detail = detail
		end,
		onCredential = function(credential: any)
			table.insert(world.credentials, credential or "none")
		end,
	}
	world.connection = Connection.start(world.config)
	world.receive = function(message: any)
		world.socket.MessageReceived.fire(if type(message) == "string" then message else serde.encode("json", message))
	end
	world.state = function(): string
		return world.states[#world.states]
	end
	return world
end

local CREDENTIAL = { id = "c1", keyHex = KEY_HEX }

-- Plays the broker's side of a handshake to the end, with the given key.
local function handshake(world: any, key: buffer)
	world.socket.Opened.fire()
	local nonce = world.sent[#world.sent].nonce
	world.receive({
		t = "challenge",
		nonce = SERVER_NONCE,
		proof = Auth.hmacHex(key, Auth.proofInput("broker", "plugin", nonce, SERVER_NONCE)),
	})
	world.receive({ t = "ready" })
end

case("nothing but a hello is sent until the broker has proved itself", function()
	local world = start({ credential = CREDENTIAL })
	check("it dials the loopback port", world.socket.port == 47318 and world.state() == "connecting")
	check("and says nothing until the socket opens", #world.sent == 0)
	world.socket.Opened.fire()
	local hello = world.sent[1]
	check(
		"a hello, naming the credential and a nonce",
		#world.sent == 1
			and hello.t == "hello"
			and hello.role == "plugin"
			and hello.key == "cred:c1"
			and #hello.nonce == 32
	)
	check("the key itself is never sent", not string.find(serde.encode("json", hello), KEY_HEX, 1, true))

	local key = Codec.fromHex(KEY_HEX)
	world.receive({
		t = "challenge",
		nonce = SERVER_NONCE,
		proof = Auth.hmacHex(key, Auth.proofInput("broker", "plugin", hello.nonce, SERVER_NONCE)),
	})
	local auth = world.sent[2]
	check(
		"then its own proof",
		#world.sent == 2
			and auth.t == "auth"
			and auth.proof == Auth.hmacHex(key, Auth.proofInput("client", "plugin", hello.nonce, SERVER_NONCE))
	)
	check(
		"which differs from the broker's",
		auth.proof ~= Auth.hmacHex(key, Auth.proofInput("broker", "plugin", hello.nonce, SERVER_NONCE))
	)
	check("not yet ready", world.state() == "connecting")
	world.receive({ t = "ready" })
	check(
		"ready, and the session is announced",
		world.state() == "ready" and world.sent[3].t == "session" and world.sent[3].session.id == "s1"
	)
end)

case("a listener that cannot prove it is the broker is told nothing more", function()
	for name, reply in
		{
			["a wrong proof"] = { t = "challenge", nonce = SERVER_NONCE, proof = string.rep("0", 64) },
			["a proof made with another key"] = {
				t = "challenge",
				nonce = SERVER_NONCE,
				proof = Auth.hmacHex(
					Codec.fromHex(string.rep("cd", 32)),
					Auth.proofInput("broker", "plugin", Auth.nonceFromGuid(GUID), SERVER_NONCE)
				),
			},
			["no challenge at all"] = { t = "ready" },
			["a request before any proof"] = { t = "req", id = "1", method = "get_workspace" },
			["a short nonce"] = { t = "challenge", nonce = "55", proof = string.rep("0", 64) },
			["something that is not JSON"] = "<html>",
		} :: { [string]: any }
	do
		local ran = false
		local world = start({
			credential = CREDENTIAL,
			handler = function()
				ran = true
				return {}
			end,
		})
		world.socket.Opened.fire()
		world.receive(reply)
		task.wait()
		check(`{name}: treated as a foreign program`, world.state() == "foreign", world.state())
		check(`{name}: only the hello was ever sent`, #world.sent == 1)
		check(`{name}: the socket is closed and nothing was run`, world.socket.closed and not ran)
	end
end)

case("a broker that no longer knows the credential leads to pairing again", function()
	local world = start({ credential = CREDENTIAL })
	world.socket.Opened.fire()
	world.receive({ t = "denied", code = "unknown_credential" })
	check("the stored credential is dropped", world.credentials[1] == "none" and world.config.credential == nil)
	check("and the state says unpaired", world.state() == "unpaired")
	local refused = start({ credential = CREDENTIAL })
	refused.socket.Opened.fire()
	refused.receive({ t = "denied", code = "bad_proof" })
	check(
		"any other refusal is reported as such",
		refused.state() == "denied" and refused.detail == "bad_proof" and #refused.credentials == 0
	)
end)

case("a broker of another release says which half is older, and is asked again later", function()
	for theirs, older in { [99] = "plugin_older", [0] = "adapter_older" } do
		local world = start({ credential = CREDENTIAL })
		world.socket.Opened.fire()
		world.receive({ t = "denied", code = "version", v = theirs })
		check(`protocol {theirs}: {older}`, world.state() == "denied" and world.detail == older, world.detail)
		check(`protocol {theirs}: the credential is kept`, #world.credentials == 0)
		local again = world.timers[#world.timers]
		check(`protocol {theirs}: it asks again later`, again and again.seconds == 10)
	end
end)

case("pairing waits for the code to be registered, then stores a derived credential", function()
	local world = start({ pairingCode = "ABCD2345EF" })
	world.socket.Opened.fire()
	check("the hello asks to pair", world.sent[1].key == "pair")
	world.receive({ t = "denied", code = "no_pairing" })
	check(
		"no code registered yet: unpaired, and the code is kept",
		world.state() == "unpaired" and world.config.pairingCode == "ABCD2345EF"
	)
	local again = world.timers[#world.timers]
	check("it asks again shortly", again.seconds == 2)
	again.work()
	check("on a new socket", #world.sockets == 2 and world.sockets[1].closed)

	local key = Auth.pairingKey("ABCD2345EF")
	world.socket.Opened.fire()
	local nonce = world.sent[#world.sent].nonce
	world.receive({
		t = "challenge",
		nonce = SERVER_NONCE,
		proof = Auth.hmacHex(key, Auth.proofInput("broker", "plugin", nonce, SERVER_NONCE)),
	})
	world.receive({ t = "ready", credential = "newid" })
	local stored = world.credentials[1]
	check("the credential the broker named is stored", stored.id == "newid" and world.state() == "ready")
	check(
		"with a key derived from the code and both nonces",
		stored.keyHex == Auth.deriveCredentialKeyHex(key, nonce, SERVER_NONCE)
	)
	check("and the code is spent", world.config.pairingCode == nil)

	local none = start({})
	check("with neither a credential nor a code, nothing is dialled", none.state() == "unpaired" and #none.sockets == 0)
	local bare = start({ pairingCode = "ABCD2345EF" })
	bare.socket.Opened.fire()
	local bareNonce = bare.sent[1].nonce
	bare.receive({
		t = "challenge",
		nonce = SERVER_NONCE,
		proof = Auth.hmacHex(key, Auth.proofInput("broker", "plugin", bareNonce, SERVER_NONCE)),
	})
	bare.receive({ t = "ready" })
	check("a pairing that returns no credential is refused", bare.state() == "denied" and #bare.credentials == 0)
end)

case("requests are answered one at a time, in order", function()
	local order = {}
	local world = start({
		credential = CREDENTIAL,
		handler = function(method: string, params: any)
			table.insert(order, method)
			task.wait()
			if method == "fails" then
				error({ code = "INVALID_ARGUMENT", message = "no" })
			end
			return { got = params and params.n }
		end,
	})
	handshake(world, Codec.fromHex(KEY_HEX))
	local base = #world.sent
	world.receive({ t = "req", id = "a", method = "first", params = { n = 1 } })
	world.receive({ t = "req", id = "b", method = "fails" })
	world.receive({ t = "req", id = "c", method = "third", params = { n = 3 } })
	for _ = 1, 10 do
		task.wait()
	end
	check(
		"all three ran, in the order they came",
		table.concat(order, " ") == "first fails third",
		table.concat(order, " ")
	)
	local a, b, c = world.sent[base + 1], world.sent[base + 2], world.sent[base + 3]
	check("each answered under its own id", a.id == "a" and b.id == "b" and c.id == "c")
	check("a result is passed on", a.ok == true and a.result.got == 1 and c.result.got == 3)
	check("and so is an error, with its code", b.ok == false and b.error.code == "INVALID_ARGUMENT")
end)

case("a request nobody waits for is dropped or told to stop", function()
	local ran = {}
	local world = start({
		credential = CREDENTIAL,
		handler = function(method: string)
			table.insert(ran, method)
			for _ = 1, 3 do
				task.wait()
			end
			return {}
		end,
	})
	handshake(world, Codec.fromHex(KEY_HEX))
	local base = #world.sent
	world.receive({ t = "req", id = "a", method = "running" })
	world.receive({ t = "req", id = "b", method = "waiting" })
	world.receive({ t = "cancel", id = "b" })
	world.receive({ t = "cancel", id = "a" })
	for _ = 1, 12 do
		task.wait()
	end
	check("the one still waiting never ran", table.concat(ran, " ") == "running", table.concat(ran, " "))
	check("the one running was told to stop", #world.cancels == 1 and string.find(world.cancels[1], "abandoned") ~= nil)
	check("and neither was answered", #world.sent == base, #world.sent - base)
end)

case("a request that never returns is given up on, and the next is answered", function()
	local world = start({
		credential = CREDENTIAL,
		handler = function(method: string)
			if method == "stuck" then
				coroutine.yield()
			end
			return { done = method }
		end,
	})
	handshake(world, Codec.fromHex(KEY_HEX))
	local base = #world.sent
	world.receive({ t = "req", id = "a", method = "stuck" })
	world.receive({ t = "req", id = "b", method = "after" })
	for _ = 1, Connection.REQUEST_LIMIT + 20 do
		task.wait()
	end
	local a, b = world.sent[base + 1], world.sent[base + 2]
	check(
		"the stuck request is answered with a timeout",
		a and a.id == "a" and a.ok == false and a.error.code == "TIMEOUT",
		a and a.error and a.error.code
	)
	check(
		"work that can be stopped was told to",
		#world.cancels == 1 and string.find(world.cancels[1], "time limit") ~= nil
	)
	check("and the request behind it is answered", b and b.id == "b" and b.ok == true and b.result.done == "after")
end)

case("a lost connection is retried, and stopping ends it", function()
	local world = start({ credential = CREDENTIAL })
	handshake(world, Codec.fromHex(KEY_HEX))
	world.socket.Closed.fire()
	check(
		"lost: disconnected, with a retry set",
		world.state() == "disconnected" and world.timers[#world.timers].seconds == 0.5
	)
	world.timers[#world.timers].work()
	check("the retry dials again", #world.sockets == 2 and world.state() == "connecting")
	world.socket.Error.fire(0, "refused")
	check(
		"each failure in a row waits longer",
		world.timers[#world.timers].seconds == 1,
		world.timers[#world.timers].seconds
	)

	local sockets = #world.sockets
	world.connection.stop()
	check("stopped", world.state() == "stopped" and world.socket.closed)
	for _, timer in world.timers do
		timer.work()
	end
	check("and no timer brings it back", #world.sockets == sockets and world.state() == "stopped")

	local stale = start({ credential = CREDENTIAL })
	stale.socket.Opened.fire()
	local handshakeTimer = stale.timers[1]
	check("a handshake has a deadline", handshakeTimer.seconds == 5)
	handshakeTimer.work()
	check(
		"a broker that never answers is given up on",
		stale.state() == "disconnected" and stale.detail == "handshake timed out"
	)
end)

print(`{count - failures}/{count} connection checks passed`)
if failures > 0 then
	process.exit(1)
end
