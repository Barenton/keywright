--!strict
-- Holding a hand or foot in place, on a moving floor, against another part, or rolling.

local Frames = require("./Frames")
local Body = require("./Body")
local Limb = require("../../Rigs/Limb")
local Need = require("./Need")
local Pose = require("../../Rigs/Pose")
local Rig = require("../../Rigs/Rig")
local Roblox = require("../../Core/Roblox")
local Store = require("./Store")
local Write = require("./Write")

local count = Frames.count
local floorOf = Body.floorOf
local FRAME_SLACK = Frames.FRAME_SLACK
local hasGeometry = Body.hasGeometry
local isFinite = Need.isFinite
local milliseconds = Need.milliseconds
local needBlends = Need.needBlends
local needJoint = Need.needJoint
local needOneOf = Need.needOneOf
local needRange = Need.needRange
local needTime = Need.needTime
local needVector = Need.needVector
local readChannels = Frames.readChannels
local refuse = Need.refuse
local rounded = Need.rounded
local smoothstep = Frames.smoothstep
local transformsAt = Frames.transformsAt
local writeFrames = Write.writeFrames
local writeTurns = Write.writeTurns

type Changed = Frames.Changed
type Context = Frames.Context

local Ops = {}

Ops.pin = {
	-- Its range may run across a looping clip's end (see Seam).
	wraps = true,

	check = function(where: string, operation: any, joints: { [string]: any })
		local chain = if type(operation.part) == "string" then Limb.CHAINS[operation.part] else nil
		if not chain then
			refuse(where, "part must be LeftFoot, RightFoot, LeftHand or RightHand.")
		end
		for _, name in chain :: { string } do
			needJoint(where, name, joints)
		end
		needRange(where, operation, true)
		if operation.at ~= nil then
			needTime(where, operation.at, "at")
		end
		needVector(where, operation.position, "position", Store.MAX_POSITION)
		needVector(where, operation.pole, "pole", Store.MAX_POSITION)
		if operation.pivot ~= nil then
			needOneOf(where, operation.pivot, "pivot", Store.PIVOTS)
			if operation.pivot ~= "ankle" then
				if operation.part ~= "LeftFoot" and operation.part ~= "RightFoot" then
					refuse(where, "a toe or heel pivot is for a foot.")
				end
				if operation.hold == "position" then
					refuse(where, "a toe or heel pivot sets how the foot turns; hold position holds the ankle instead.")
				end
			end
		end
		if operation.travel ~= "match" then
			needVector(where, operation.travel, "travel", 100)
		end
		if operation.fit_hips ~= nil and type(operation.fit_hips) ~= "boolean" then
			refuse(where, "fit_hips must be true or false.")
		end
		if operation.fit_hips and operation.relative_to ~= nil then
			refuse(where, "fit_hips moves the hips, which a part held relative_to would move with.")
		end
		if operation.keep ~= nil then
			if not operation.fit_hips then
				refuse(where, "keep is for fit_hips: the limbs held still while the hips move.")
			end
			if type(operation.keep) ~= "table" then
				refuse(where, "keep must list hands or feet.")
			end
			for _, name in operation.keep do
				if type(name) ~= "string" or not Limb.CHAINS[name] or name == operation.part then
					refuse(where, "keep must list other hands or feet: LeftFoot, RightFoot, LeftHand, RightHand.")
				end
				for _, joint in Limb.CHAINS[name] do
					needJoint(where, joint, joints)
				end
			end
		end
		if operation.roll ~= nil then
			if operation.pivot ~= "toe" and operation.pivot ~= "heel" then
				refuse(where, "roll is for a toe or heel pivot.")
			end
			if type(operation.roll) ~= "table" or #operation.roll ~= 2 then
				refuse(where, "roll must be two angles in degrees: at time_from and at time_to.")
			end
			for _, angle in operation.roll do
				if not isFinite(angle) or angle < 0 or angle > 90 then
					refuse(where, "each roll angle must be from 0 to 90 degrees.")
				end
			end
		end
		local soft = operation.soft
		if soft ~= nil and (not isFinite(soft) or soft < 0 or soft > 0.5) then
			refuse(where, "soft must be from 0 to 0.5.")
		end
		if operation.on_floor ~= nil and type(operation.on_floor) ~= "boolean" then
			refuse(where, "on_floor must be true or false.")
		end
		if operation.on_floor and operation.relative_to ~= nil then
			refuse(where, "on_floor holds the part on the floor, so it cannot also be relative_to another part.")
		end
		if operation.relative_to ~= nil then
			needJoint(where, operation.relative_to, joints)
			if table.find(chain :: { string }, operation.relative_to) then
				refuse(where, `relative_to cannot be a part of the limb being pinned.`)
			end
		end
		if operation.hold ~= nil then
			needOneOf(where, operation.hold, "hold", Store.HOLDS)
		end
		needBlends(where, operation)
	end,

	apply = function(where: string, clip: Instance, operation: any, context: Context, changed: Changed)
		local chain = Limb.CHAINS[operation.part]
		local joints = context.joints
		if not hasGeometry(joints, chain) then
			refuse(where, "this rig's limb could not be measured, so nothing can be pinned on it.")
		end
		local duration = Store.duration(clip)
		if operation.time_to > duration + Store.TIME_TOLERANCE then
			refuse(
				where,
				`the clip ends at {milliseconds(duration)} seconds, before time_to.`,
				"Key the clip out to its full length first."
			)
		end
		local from, to = operation.time_from, operation.time_to
		local first = math.max(0, from - (operation.blend_in or 0))
		local last = math.min(duration, to + (operation.blend_out or 0))
		local rate = Store.FRAME_RATE
		local firstFrame = math.ceil(first * rate - FRAME_SLACK)
		local lastFrame = math.floor(last * rate + FRAME_SLACK)
		if lastFrame < firstFrame then
			refuse(where, "the range holds no whole frame; Studio shows a curve clip only at whole frames.")
		end

		-- Everything is worked out from the clip as it is, before anything is written.
		local channels = readChannels(clip)
		local scan = { joints = joints } :: any
		local identity = Roblox.CFrame.new()
		local limb = { joints[chain[1]], joints[chain[2]], joints[chain[3]] }
		-- The part the target moves with, if any: the target is kept in its frame, so a
		-- hand held to the chest stays on the chest as the body bends.
		local anchorName = operation.relative_to
		local function anchorOf(placed: { [string]: CFrame }): CFrame
			return if anchorName then placed[anchorName] else identity
		end
		local reference = Pose.place(scan, transformsAt(channels, operation.at or from), identity)
		-- The target, in the anchor's frame.
		local tipLocal = anchorOf(reference):Inverse() * reference[chain[3]]
		if operation.position then
			local p = operation.position
			tipLocal = Roblox.CFrame.new(p[1], p[2], p[3]) * (tipLocal - tipLocal.Position)
		end
		if operation.on_floor then
			-- Where it is, but set flat, turned only about the vertical, with its underside
			-- on the floor.
			local here = tipLocal.Position
			local look = tipLocal.LookVector
			local heading = Roblox.Vector3.new(look.X, 0, look.Z)
			if heading.Magnitude < 1e-6 then
				heading = Roblox.Vector3.new(0, 0, -1)
			end
			local size = joints[chain[3]].part1.Size
			local standing = Roblox.Vector3.new(here.X, floorOf(joints) + size.Y / 2, here.Z)
			tipLocal = Roblox.CFrame.lookAt(standing, standing + heading.Unit)
		end
		-- With a toe or heel pivot, that point of the foot is what stays put, and the foot
		-- turns about it by the roll asked for: its other end lifted off the floor by an
		-- angle that eases from the first given to the second across the range.
		local rolling = operation.pivot == "toe" or operation.pivot == "heel"
		local offset = Roblox.Vector3.new()
		local pointLocal = Roblox.Vector3.new()
		local heldTurn = identity
		if rolling then
			local size = joints[chain[3]].part1.Size
			-- A rig faces along its own negative Z: the toe is the front of the sole.
			offset = Roblox.Vector3.new(0, -size.Y / 2, if operation.pivot == "toe" then -size.Z / 2 else size.Z / 2)
			local atFoot = anchorOf(reference):Inverse() * reference[chain[3]]
			pointLocal = atFoot:PointToWorldSpace(offset)
			heldTurn = atFoot - atFoot.Position
			if operation.position then
				local p = operation.position
				pointLocal = Roblox.Vector3.new(p[1], p[2], p[3])
			end
			if operation.on_floor then
				pointLocal = Roblox.Vector3.new(pointLocal.X, floorOf(joints), pointLocal.Z)
				-- Flat on the floor before it rolls: turned only about the vertical.
				local look = heldTurn.LookVector
				local heading = Roblox.Vector3.new(look.X, 0, look.Z)
				if heading.Magnitude < 1e-6 then
					heading = Roblox.Vector3.new(0, 0, -1)
				end
				heldTurn = Roblox.CFrame.lookAt(Roblox.Vector3.new(), heading.Unit)
			end
		end
		local rollFrom = math.rad(if operation.roll then operation.roll[1] else 0)
		local rollTo = math.rad(if operation.roll then operation.roll[2] else 0)
		-- Lifting the heel turns the foot one way about its own X axis, lifting the toes the
		-- other.
		local lift = if operation.pivot == "toe" then -1 else 1
		if rolling and not operation.on_floor then
			-- The foot is taken to be rolled already by the first angle where it is held,
			-- as after another roll; its facing flat is that, rolled back.
			heldTurn = heldTurn * Roblox.CFrame.Angles(-lift * rollFrom, 0, 0)
		end
		local full = rolling or (operation.hold or "full") == "full"
		local poleLocal = if operation.pole
			then Roblox.Vector3.new(operation.pole[1], operation.pole[2], operation.pole[3])
			else nil

		-- The floor's speed: as given, or with "match" the clip's own motion of the held
		-- point from the start of the range to its end, before this pin changes it.
		local travel: Vector3? = nil
		if operation.travel == "match" then
			local function heldPoint(time: number): Vector3
				local placed = Pose.place(scan, transformsAt(channels, time), identity)
				local part = anchorOf(placed):Inverse() * placed[chain[3]]
				return if rolling then part:PointToWorldSpace(offset) else part.Position
			end
			local velocity = (heldPoint(to) - heldPoint(from)) / math.max(to - from, 1e-6)
			if operation.on_floor then
				velocity = Roblox.Vector3.new(velocity.X, 0, velocity.Z)
			end
			travel = velocity
			changed.travel_x = rounded(velocity.X, 3)
			changed.travel_y = rounded(velocity.Y, 3)
			changed.travel_z = rounded(velocity.Z, 3)
		elseif operation.travel then
			travel = Roblox.Vector3.new(operation.travel[1], operation.travel[2], operation.travel[3])
		end

		-- For fit_hips: which way is up for the hips' position, the hips' drop at each
		-- frame, and the limbs to keep where they are.
		local rootC0 = Rig.rest(joints.LowerTorso)
		local hipsUp = rootC0:VectorToObjectSpace(Roblox.Vector3.new(0, 1, 0))
		local drops: { number } = {}
		local hipsDropped, deepest = 0, 0
		local keepChains: { { part: string, chain: { string }, limb: { any }, turns: { [string]: { CFrame } } } } = {}
		for _, name in operation.keep or {} do
			local other = Limb.CHAINS[name]
			table.insert(keepChains, {
				part = name,
				chain = other,
				limb = { joints[other[1]], joints[other[2]], joints[other[3]] },
				turns = { [other[1]] = {}, [other[2]] = {}, [other[3]] = {} },
			})
		end

		local frames: { { time: number, transforms: { CFrame } } } = {}
		local missed, worst, softened = 0, 0, 0
		local missedFrom, missedTo = math.huge, -math.huge
		for frame = firstFrame, lastFrame do
			local time = frame / rate
			local transforms = transformsAt(channels, time)
			local placed = Pose.place(scan, transforms, identity)
			local current = { transforms[chain[1]], transforms[chain[2]], transforms[chain[3]] }
			local anchor = anchorOf(placed)
			local tip = anchor * tipLocal
			-- On a moving floor, as for a cycle made on the spot: the held point moves on
			-- steadily from where it was at `at`, through the blends too, so a foot eased
			-- in is already moving with the floor when it lands, and one eased out leaves
			-- with it.
			local moved = Roblox.Vector3.new()
			if travel then
				moved = travel * (time - (operation.at or from))
			end
			if rolling then
				local along = smoothstep((time - from) / math.max(to - from, 1e-6))
				local angle = rollFrom + (rollTo - rollFrom) * along
				local turned = heldTurn * Roblox.CFrame.Angles(lift * angle, 0, 0)
				tip = anchor * Roblox.CFrame.new(pointLocal + moved) * turned * Roblox.CFrame.new(-offset)
			elseif travel then
				tip = anchor * (tipLocal + moved)
			end
			local weight = 1
			if time < from - Store.TIME_TOLERANCE then
				weight = smoothstep((time - first) / math.max(from - first, 1e-6))
			elseif time > to + Store.TIME_TOLERANCE then
				weight = smoothstep((last - time) / math.max(last - to, 1e-6))
			end
			-- Easing in or out, the target itself moves from where the animation has the part
			-- to where it is held, and the limb reaches for it. The part then travels straight
			-- between the two, instead of wherever angles part way between would put it.
			local free = placed[chain[3]]
			if weight < 1 then
				tip = free:Lerp(tip, weight)
			end
			-- Where the point is beyond the limb's reach, the hips go straight down by
			-- just enough for it to be reached; the limbs named in keep are turned to stay
			-- where they were.
			local drop = 0
			if operation.fit_hips and weight > 0 then
				local upper = Limb.upperOf(placed[Rig.R15_PARENTS[chain[1]]], limb[1], current[1])
				local reach = Limb.fullest(limb, current) * (1 - (operation.soft or 0)) - 1e-4
				local away = upper - Limb.pivotOf(limb[3], tip)
				if away.Magnitude > reach then
					local room = away.Y * away.Y - away:Dot(away) + reach * reach
					drop = math.max(0, if room >= 0 then away.Y - math.sqrt(room) else away.Y)
				end
				if drop > 0 then
					local before = placed
					transforms = table.clone(transforms)
					transforms.LowerTorso = Roblox.CFrame.new(hipsUp * -drop) * transforms.LowerTorso
					placed = Pose.place(scan, transforms, identity)
					current = { transforms[chain[1]], transforms[chain[2]], transforms[chain[3]] }
					for _, other in keepChains do
						local held = Limb.solve({
							parent = placed[Rig.R15_PARENTS[other.chain[1]]],
							joints = other.limb,
							current = {
								transforms[other.chain[1]],
								transforms[other.chain[2]],
								transforms[other.chain[3]],
							},
							pivot = Limb.pivotOf(other.limb[3], before[other.chain[3]]),
							tip = before[other.chain[3]],
							bend = Limb.BEND[other.part],
						})
						for index, joint in other.chain do
							transforms[joint] = held.transforms[index]
						end
					end
					hipsDropped += 1
					deepest = math.max(deepest, drop)
				end
			end
			drops[frame - firstFrame + 1] = drop
			for _, other in keepChains do
				for _, joint in other.chain do
					other.turns[joint][frame - firstFrame + 1] = transforms[joint]
				end
			end
			local solution = if weight <= 0
				then { transforms = current, miss = 0, beyond = false }
				else Limb.solve({
					parent = placed[Rig.R15_PARENTS[chain[1]]],
					joints = limb,
					current = current,
					pivot = Limb.pivotOf(limb[3], tip),
					tip = if full then tip else nil,
					bend = Limb.BEND[operation.part],
					pole = if poleLocal then anchor * poleLocal else nil,
					poleWeight = weight,
					soft = operation.soft,
				})
			local result = solution.transforms
			if weight >= 1 and not solution.beyond and solution.miss > 0.001 then
				-- Short of the point only because the reach was softened.
				softened = math.max(softened, solution.miss)
			elseif weight >= 1 and solution.miss > 0.001 then
				missed += 1
				worst = math.max(worst, solution.miss)
				missedFrom = math.min(missedFrom, time)
				missedTo = math.max(missedTo, time)
			end
			table.insert(frames, { time = time, transforms = result })
		end

		-- The three joints' rotation keys in the range are replaced by one key a frame.
		for index, joint in chain do
			local turns = {}
			for frame, entry in frames do
				turns[frame] = entry.transforms[index]
			end
			writeTurns(clip, joint, channels[joint] or {}, firstFrame, lastFrame, turns, duration, changed, false)
		end
		if hipsDropped > 0 then
			-- The hips' position, lowered where it had to be, and the limbs kept still.
			local own = channels.LowerTorso or {}
			for axis, letter in { "x", "y", "z" } do
				local share = ({ hipsUp.X, hipsUp.Y, hipsUp.Z })[axis]
				if math.abs(share) < 1e-9 then
					continue
				end
				local channel = `position.{letter}`
				local original = own[channel] or {}
				local values = {}
				for index, drop in drops do
					values[index] = Store.evaluate(original, (firstFrame + index - 1) / rate) - drop * share
				end
				writeFrames(clip, "LowerTorso", channel, original, {
					first = firstFrame,
					last = lastFrame,
					values = values,
					duration = duration,
				}, changed)
			end
			for _, other in keepChains do
				for _, joint in other.chain do
					writeTurns(
						clip,
						joint,
						channels[joint] or {},
						firstFrame,
						lastFrame,
						other.turns[joint],
						duration,
						changed,
						false
					)
				end
			end
			count(changed, "frames_hips_lowered", hipsDropped)
			changed.largest_hip_drop_studs = math.max(changed.largest_hip_drop_studs or 0, rounded(deepest, 3))
		end
		count(changed, "frames_pinned", #frames)
		if softened > 0 then
			changed.largest_soft_studs = math.max(changed.largest_soft_studs or 0, rounded(softened, 3))
		end
		if missed > 0 then
			count(changed, "frames_out_of_reach", missed)
			changed.largest_miss_studs = math.max(changed.largest_miss_studs or 0, rounded(worst, 3))
			-- When, so the hips can be fixed there: the first and last frame out of reach.
			changed.out_of_reach_from = math.min(changed.out_of_reach_from or math.huge, milliseconds(missedFrom))
			changed.out_of_reach_to = math.max(changed.out_of_reach_to or -math.huge, milliseconds(missedTo))
		end
	end,
}

return Ops
