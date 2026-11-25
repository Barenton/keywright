--!strict
-- Checks of an operation's fields, shared by every operation: each refuses with the reason.

local Errors = require("../../Core/Errors")
local Store = require("./Store")

local Need = {}

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function milliseconds(time: number): number
	return math.round(time * 1000) / 1000
end

local function rounded(value: number, places: number): number
	local scale = 10 ^ places
	return math.round(value * scale) / scale
end

local function refuse(where: string, message: string, hint: string?): never
	return Errors.throw("INVALID_ARGUMENT", `{where}: {message}`, hint)
end

local function needTime(where: string, value: any, field: string)
	if not isFinite(value) or value < 0 or value > Store.MAX_TIME then
		refuse(where, `{field} must be from 0 to {Store.MAX_TIME} seconds.`)
	end
end

local function needJoint(where: string, name: any, joints: { [string]: any })
	if type(name) ~= "string" or not joints[name] then
		refuse(where, `the rig has no joint "{tostring(name)}".`, "Call inspect_rig for the joint names.")
	end
end

local function needVector(where: string, value: any, field: string, limit: number?)
	if value == nil then
		return
	end
	if type(value) ~= "table" or #value ~= 3 then
		refuse(where, `{field} must be three numbers.`)
	end
	for index = 1, 3 do
		if not isFinite(value[index]) or (limit and math.abs(value[index]) > limit) then
			refuse(where, `{field} must be three finite numbers{if limit then ` within {limit}` else ""}.`)
		end
	end
end

local function needRange(where: string, operation: any)
	needTime(where, operation.time_from, "time_from")
	needTime(where, operation.time_to, "time_to")
	if operation.time_to < operation.time_from then
		refuse(where, "time_to must not be before time_from.")
	end
end

local function needJoints(where: string, list: any, joints: { [string]: any })
	if list == nil then
		return
	end
	if type(list) ~= "table" or #list == 0 or #list > Store.MAX_JOINTS then
		refuse(where, `joints must list from 1 to {Store.MAX_JOINTS} joint names.`)
	end
	for _, name in list do
		needJoint(where, name, joints)
	end
end

local function needOneOf(where: string, value: any, field: string, allowed: { string })
	if type(value) ~= "string" or not table.find(allowed, value) then
		refuse(where, `{field} must be one of {table.concat(allowed, ", ")}.`)
	end
end

local function needText(where: string, value: any, field: string, limit: number, allowEmpty: boolean?)
	if type(value) ~= "string" or #value > limit or (not allowEmpty and #value == 0) then
		refuse(where, `{field} must be text of {if allowEmpty then "at most" else "1 to"} {limit} characters.`)
	end
end

local function needBlends(where: string, operation: any)
	for _, field in { "blend_in", "blend_out" } do
		local value = operation[field]
		if value ~= nil and (not isFinite(value) or value < 0 or value > Store.MAX_BLEND) then
			refuse(where, `{field} must be from 0 to {Store.MAX_BLEND} seconds.`)
		end
	end
end

Need.isFinite = isFinite
Need.milliseconds = milliseconds
Need.rounded = rounded
Need.refuse = refuse
Need.needTime = needTime
Need.needJoint = needJoint
Need.needVector = needVector
Need.needRange = needRange
Need.needJoints = needJoints
Need.needOneOf = needOneOf
Need.needText = needText
Need.needBlends = needBlends

return Need
