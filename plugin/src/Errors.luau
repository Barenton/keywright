--!strict
-- Structured errors that cross the wire unchanged.

export type BridgeError = { code: string, message: string, hint: string? }

local Errors = {}

function Errors.new(code: string, message: string, hint: string?): BridgeError
	return { code = code, message = message, hint = hint }
end

function Errors.throw(code: string, message: string, hint: string?): never
	error(Errors.new(code, message, hint), 0)
end

-- Turns anything caught by pcall into a BridgeError. Unexpected failures become INTERNAL.
function Errors.from(caught: any): BridgeError
	if type(caught) == "table" and type(caught.code) == "string" and type(caught.message) == "string" then
		return caught
	end
	return Errors.new("INTERNAL", tostring(caught))
end

return Errors
