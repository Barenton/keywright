--!strict
-- Checks of an operation's fields, shared by every operation: each refuses with the reason.

local Errors = require("../../Core/Errors")
local Sequence = require("./Sequence")

local Need = {}

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function isVector(value: any, limit: number?): boolean
	if type(value) ~= "table" or #value ~= 3 then
		return false
	end
	for index = 1, 3 do
		if not isFinite(value[index]) or (limit and math.abs(value[index]) > limit) then
			return false
		end
	end
	return true
end

local function refuse(where: string, message: string, hint: string?): never
	return Errors.throw("INVALID_ARGUMENT", `{where}: {message}`, hint)
end

local function needTime(where: string, value: any, field: string)
	if not isFinite(value) or value < 0 or value > Sequence.MAX_TIME then
		refuse(where, `{field} must be from 0 to {Sequence.MAX_TIME} seconds.`)
	end
end

local function needRange(where: string, operation: any)
	needTime(where, operation.time_from, "time_from")
	needTime(where, operation.time_to, "time_to")
	if operation.time_to < operation.time_from then
		refuse(where, "time_to must not be before time_from.")
	end
end

local function needJoint(where: string, operation: any, joints: { [string]: any })
	if type(operation.joint) ~= "string" or not joints[operation.joint] then
		refuse(where, `the rig has no joint "{tostring(operation.joint)}".`, "Call inspect_rig for the joint names.")
	end
end

local function needOffset(where: string, operation: any)
	if operation.position ~= nil and not isVector(operation.position, Sequence.MAX_POSITION) then
		refuse(where, `position must be three finite numbers within {Sequence.MAX_POSITION} studs.`)
	end
	if operation.rotation ~= nil and not isVector(operation.rotation) then
		refuse(where, "rotation must be three finite numbers in degrees.")
	end
	local quaternion = operation.quaternion
	if quaternion ~= nil then
		if operation.rotation ~= nil then
			refuse(where, "give rotation or quaternion, not both.")
		end
		local squares = 0
		for index = 1, 4 do
			if type(quaternion) ~= "table" or #quaternion ~= 4 or not isFinite(quaternion[index]) then
				refuse(where, "quaternion must be four finite numbers: x, y, z, w.")
			end
			squares += quaternion[index] ^ 2
		end
		if math.abs(math.sqrt(squares) - 1) > 0.01 then
			refuse(where, "quaternion must have a length of 1.")
		end
	end
	if operation.position == nil and operation.rotation == nil and quaternion == nil then
		refuse(where, "give position, a rotation, or both.")
	end
end

local function needText(where: string, value: any, field: string, limit: number, allowEmpty: boolean?)
	if type(value) ~= "string" or #value > limit or (not allowEmpty and #value == 0) then
		refuse(where, `{field} must be text of {if allowEmpty then "at most" else "1 to"} {limit} characters.`)
	end
end

local function needOneOf(where: string, value: any, field: string, allowed: { string }, hint: string?)
	if type(value) ~= "string" or not table.find(allowed, value) then
		refuse(where, `{field} must be one of {table.concat(allowed, ", ")}.`, hint)
	end
end

local function needEasing(where: string, operation: any, style: any, direction: any)
	if style ~= nil then
		needOneOf(
			where,
			style,
			"easing_style",
			Sequence.EASING_STYLES,
			if style == "Cubic" then "Cubic is deprecated. Use CubicV2." else nil
		)
	end
	if direction ~= nil then
		needOneOf(where, direction, "easing_direction", Sequence.EASING_DIRECTIONS)
	end
end

Need.isFinite = isFinite
Need.isVector = isVector
Need.refuse = refuse
Need.needTime = needTime
Need.needRange = needRange
Need.needJoint = needJoint
Need.needOffset = needOffset
Need.needText = needText
Need.needOneOf = needOneOf
Need.needEasing = needEasing

return Need
