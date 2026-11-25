--!strict
-- Timing: shifting and scaling a range of keyframes.

local Need = require("./Need")
local Sequence = require("./Sequence")
local Write = require("./Write")

local isFinite = Need.isFinite
local needRange = Need.needRange
local needTime = Need.needTime
local refuse = Need.refuse
local retime = Write.retime

type Changed = Sequence.Changed
type Context = Sequence.Context

local Ops = {}

Ops.shift_time = {
	check = function(where: string, operation: any)
		needRange(where, operation)
		if not isFinite(operation.offset) or operation.offset == 0 then
			refuse(where, "offset must be a number of seconds other than 0.")
		end
		if operation.wrap then
			refuse(where, "wrap is for curve clips.")
		end
	end,

	apply = function(where: string, sequence: Instance, operation: any, _context: Context, changed: Changed)
		retime(where, sequence, operation, function(time)
			return time + operation.offset
		end, changed)
	end,
}

Ops.scale_time = {
	check = function(where: string, operation: any)
		needRange(where, operation)
		local factor = operation.factor
		if not isFinite(factor) or factor < Sequence.MIN_SCALE or factor > Sequence.MAX_SCALE or factor == 1 then
			refuse(where, `factor must be from {Sequence.MIN_SCALE} to {Sequence.MAX_SCALE}, and not 1.`)
		end
		if operation.anchor ~= nil then
			needTime(where, operation.anchor, "anchor")
		end
		if operation.ripple ~= nil and type(operation.ripple) ~= "boolean" then
			refuse(where, "ripple must be true or false.")
		end
	end,

	apply = function(where: string, sequence: Instance, operation: any, _context: Context, changed: Changed)
		local anchor = if operation.anchor ~= nil then operation.anchor else operation.time_from
		local function scaled(time: number): number
			return anchor + (time - anchor) * operation.factor
		end
		if not operation.ripple then
			retime(where, sequence, operation, scaled, changed)
			return
		end
		-- Everything after the range moves by as much as the range's end does, so the rest
		-- of the clip keeps its timing.
		local stretch = scaled(operation.time_to) - operation.time_to
		local range = table.clone(operation)
		range.time_to = Sequence.MAX_TIME
		retime(where, sequence, range, function(time)
			return if time <= operation.time_to + Sequence.TIME_TOLERANCE then scaled(time) else time + stretch
		end, changed)
	end,
}

return Ops
