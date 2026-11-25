--!strict
-- Follow-through: a chain trailing the body's motion through a damped spring.

local Frames = require("./Frames")
local Body = require("./Body")
local Need = require("./Need")
local Pose = require("../../Rigs/Pose")
local Rig = require("../../Rigs/Rig")
local Roblox = require("../../Core/Roblox")
local Store = require("./Store")
local Write = require("./Write")

local count = Frames.count
local hasGeometry = Body.hasGeometry
local isFinite = Need.isFinite
local near = Frames.near
local needBlends = Need.needBlends
local needJoints = Need.needJoints
local needRange = Need.needRange
local readChannels = Frames.readChannels
local refuse = Need.refuse
local spanOf = Frames.spanOf
local transformsAt = Frames.transformsAt
local writeTurns = Write.writeTurns

type Changed = Frames.Changed
type Context = Frames.Context

local Ops = {}

Ops.overlap = {
	-- Its range may run across a looping clip's end (see Seam).
	wraps = true,

	check = function(where: string, operation: any, joints: { [string]: any })
		if type(operation.joints) ~= "table" or #operation.joints == 0 then
			refuse(where, "joints must name at least one joint.")
		end
		needJoints(where, operation.joints, joints)
		needRange(where, operation, true)
		local lag = operation.lag
		if lag ~= nil and (not isFinite(lag) or lag < Store.MIN_LAG or lag > Store.MAX_LAG) then
			refuse(where, `lag must be from {Store.MIN_LAG} to {Store.MAX_LAG} seconds.`)
		end
		local bounce = operation.bounce
		if bounce ~= nil and (not isFinite(bounce) or bounce < 0 or bounce > Store.MAX_BOUNCE) then
			refuse(where, `bounce must be from 0 to {Store.MAX_BOUNCE}.`)
		end
		local weight = operation.weight
		if weight ~= nil and (not isFinite(weight) or weight < 0 or weight > 1) then
			refuse(where, "weight must be from 0 to 1.")
		end
		needBlends(where, operation)
	end,

	apply = function(where: string, clip: Instance, operation: any, context: Context, changed: Changed)
		local joints = context.joints
		if not hasGeometry(joints, Rig.R15_ORDER) then
			refuse(where, "this rig's joints could not be measured, so nothing can trail on it.")
		end
		local span = spanOf(where, clip, operation)
		local channels = readChannels(clip)
		local scan = { joints = joints } :: any
		local identity = Roblox.CFrame.new()
		local function turnOf(cframe: CFrame): CFrame
			return cframe - cframe.Position
		end
		-- From the body outward, so that each joint trails a parent that already trails.
		local named: { [string]: boolean } = {}
		for _, name in operation.joints do
			named[name] = true
		end
		local chain: { string } = {}
		for _, name in Rig.R15_ORDER do
			if named[name] then
				table.insert(chain, name)
			end
		end
		local rests: { [string]: { CFrame } } = {}
		for _, name in chain do
			local c0, c1 = Rig.rest(joints[name])
			rests[name] = { turnOf(c0), turnOf(c1) }
		end

		-- A damped spring on each part's turn in the room, pulled toward where the clip
		-- would put it on its (trailing) parent: it lags into a move and, with bounce, swings
		-- past where it stops before settling.
		-- The lag is shared along the chain, so its end trails by about that much: springs
		-- one after another each add their own.
		local lag = operation.lag or 0.1
		local stiffness = #chain / lag
		local damping = 1 - (operation.bounce or 0.3)
		local weight = operation.weight or 1
		local rate = Store.FRAME_RATE
		local steps = 8
		local dt = 1 / rate / steps
		local duration = Store.duration(clip)
		local whole = near(operation.time_from, 0) and near(operation.time_to, duration)
		local looping = (clip :: any).Loop == true and whole
		local frameCount = span.last - span.first + 1

		local animated: { { [string]: CFrame } } = {}
		local frames: { { [string]: CFrame } } = {}
		for index = 1, frameCount do
			local transforms = transformsAt(channels, (span.first + index - 1) / rate)
			animated[index] = transforms
			frames[index] = Pose.place(scan, transforms, identity)
		end
		local state: { [string]: { turn: CFrame, spin: Vector3 } } = {}
		local turns: { [string]: { CFrame } } = {}
		for _, name in chain do
			turns[name] = {}
		end
		-- A looping clip is run round three times and the last kept, by when the springs
		-- have settled into the cycle, so the motion comes back round to where it began.
		local passes = if looping then 3 else 1
		for pass = 1, passes do
			-- In a loop the last frame is the first one again, so the round before the one
			-- kept stops short of it.
			local last = if pass < passes then frameCount - 1 else frameCount
			for index = 1, last do
				local time = (span.first + index - 1) / rate
				local placed = frames[index]
				local blend = weight * span.weight(time)
				local final: { [string]: CFrame } = {}
				for _, name in chain do
					local parentName = Rig.R15_PARENTS[name]
					local parent = final[parentName] or turnOf(placed[parentName] or identity)
					local c0, c1 = rests[name][1], rests[name][2]
					local own = turnOf(animated[index][name])
					-- Where the clip would put the part on its parent as it now is.
					local goal = parent * c0 * own * c1:Inverse()
					local spring = state[name]
					if not spring then
						spring = { turn = goal, spin = Roblox.Vector3.new() }
						state[name] = spring
					end
					for _ = 1, steps do
						local axis, angle = (goal * spring.turn:Inverse()):ToAxisAngle()
						local pull = if angle > 1e-9 then axis.Unit * angle else Roblox.Vector3.new()
						spring.spin += (pull * stiffness * stiffness - spring.spin * 2 * damping * stiffness) * dt
						local step = spring.spin * dt
						if step.Magnitude > 1e-12 then
							spring.turn = Roblox.CFrame.fromAxisAngle(step.Unit, step.Magnitude) * spring.turn
						end
					end
					local result = goal:Lerp(spring.turn, blend)
					final[name] = result
					if pass == passes then
						turns[name][index] = Roblox.CFrame.new(animated[index][name].Position)
							* (c0:Inverse() * parent:Inverse() * result * c1)
					end
				end
			end
		end
		for _, name in chain do
			writeTurns(clip, name, channels[name] or {}, span.first, span.last, turns[name], duration, changed, true)
		end
		count(changed, "frames_with_overlap", frameCount)
	end,
}

return Ops
