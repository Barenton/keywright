--!strict
-- Offline tests for reaching with a limb. Run with: lune run plugin/test/rigs/limb.test.luau
--
-- Real here: Lune's CFrame arithmetic, and a block rig whose knees and elbows sit off the
-- line of the limb as a real R15 rig's do. Every answer is checked by placing the rig's
-- parts with the joint transforms it gives (Pose.place), not against numbers worked out
-- by hand, so the check does not share the solver's reasoning.

local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any

local Roblox = require("../../src/Core/Roblox") :: any
Roblox.CFrame = roblox.CFrame
Roblox.Vector3 = roblox.Vector3

local BlockRig = require("./blockrig")
local Limb = require("../../src/Rigs/Limb")
local Pose = require("../../src/Rigs/Pose")
local Rig = require("../../src/Rigs/Rig")

local CFrame = roblox.CFrame
local Vector3 = roblox.Vector3

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

local scan = Rig.scan(BlockRig.build())
local identity = CFrame.new()

local function restPose(): { [string]: any }
	local transforms = {}
	for _, name in Rig.R15_ORDER do
		transforms[name] = identity
	end
	return transforms
end

local function turnBetween(a: any, b: any): number
	local squares = (a.RightVector - b.RightVector).Magnitude ^ 2
		+ (a.UpVector - b.UpVector).Magnitude ^ 2
		+ (a.LookVector - b.LookVector).Magnitude ^ 2
	return math.deg(2 * math.asin(math.min(1, math.sqrt(squares / 8))))
end

-- A random number from a to b, the same every run.
local seed = 12345
local function random(a: number, b: number): number
	seed = (seed * 1103515245 + 12345) % 2147483648
	return a + (b - a) * seed / 2147483648
end

-- Solves for a limb in a pose, applies the answer, and places the rig with it.
local function solveIn(transforms: { [string]: any }, part: string, pivot: any, tip: any?, pole: any?): (any, any)
	local chain = Limb.CHAINS[part]
	local placed = Pose.place(scan, transforms, identity)
	local solution = Limb.solve({
		parent = placed[Rig.R15_PARENTS[chain[1]]],
		joints = { scan.joints[chain[1]], scan.joints[chain[2]], scan.joints[chain[3]] },
		current = { transforms[chain[1]], transforms[chain[2]], transforms[chain[3]] },
		pivot = pivot,
		tip = tip,
		bend = Limb.BEND[part],
		pole = pole,
	})
	local after = table.clone(transforms)
	for index, name in chain do
		after[name] = solution.transforms[index]
	end
	return solution, Pose.place(scan, after, identity)
end

-- A pose a limb can reach: the joints turned at random, the middle one only about its
-- hinge and the way it bends.
local function randomLimbPose(part: string): { [string]: any }
	local chain = Limb.CHAINS[part]
	local transforms = restPose()
	transforms.LowerTorso = CFrame.new(random(-0.3, 0.3), random(-1, 0.2), random(-0.3, 0.3))
		* CFrame.Angles(random(-0.4, 0.4), random(-0.6, 0.6), random(-0.3, 0.3))
	transforms[chain[1]] = CFrame.Angles(random(-1.2, 1.2), random(-0.5, 0.5), random(-0.6, 0.6))
	transforms[chain[2]] = CFrame.Angles(Limb.BEND[part] * random(0.15, 2.2), 0, 0)
	transforms[chain[3]] = CFrame.Angles(random(-0.6, 0.6), random(-0.3, 0.3), random(-0.3, 0.3))
	return transforms
end

case("a point the limb can reach is reached, and the end part turned as asked", function()
	for _, part in { "LeftFoot", "RightFoot", "LeftHand", "RightHand" } do
		local worstStuds, worstDegrees = 0, 0
		for _ = 1, 60 do
			-- Where the limb's end is in one pose is the goal; the solver starts from another.
			local goalPose = randomLimbPose(part)
			local goal = Pose.place(scan, goalPose, identity)[part]
			local pivot = Limb.pivotOf(scan.joints[part], goal)
			local start = randomLimbPose(part)
			start.LowerTorso = goalPose.LowerTorso
			start.UpperTorso = goalPose.UpperTorso
			local solution, placed = solveIn(start, part, pivot, goal)
			worstStuds = math.max(worstStuds, solution.miss, (placed[part].Position - goal.Position).Magnitude)
			worstDegrees = math.max(worstDegrees, turnBetween(placed[part], goal))
		end
		check(`{part}: within a ten-thousandth of a stud`, worstStuds < 1e-4, worstStuds)
		check(`{part}: within a hundredth of a degree`, worstDegrees < 0.01, worstDegrees)
	end
end)

case("the knee and elbow bend the way they bend", function()
	for _, part in { "LeftFoot", "RightFoot", "LeftHand", "RightHand" } do
		local wrong = 0
		for _ = 1, 40 do
			local goalPose = randomLimbPose(part)
			local goal = Pose.place(scan, goalPose, identity)[part]
			local start = restPose()
			start.LowerTorso = goalPose.LowerTorso
			local solution = solveIn(start, part, Limb.pivotOf(scan.joints[part], goal), goal)
			local angle = solution.transforms[2]:ToEulerAnglesXYZ()
			if angle * Limb.BEND[part] < -1e-6 then
				wrong += 1
			end
		end
		check(`{part}: never bends backward`, wrong == 0, wrong)
	end
end)

case("a limb already where it is wanted is left as it is", function()
	local pose = randomLimbPose("LeftFoot")
	local here = Pose.place(scan, pose, identity).LeftFoot
	local solution = solveIn(pose, "LeftFoot", Limb.pivotOf(scan.joints.LeftFoot, here), here)
	local chain = Limb.CHAINS.LeftFoot
	for index, name in chain do
		check(`{name} keeps its turn`, turnBetween(solution.transforms[index], pose[name]) < 0.01)
	end
end)

case("without a rotation asked for, the end part keeps its own turn", function()
	local pose = randomLimbPose("RightHand")
	local goal = Pose.place(scan, randomLimbPose("RightHand"), identity).RightHand
	local solution = solveIn(pose, "RightHand", Limb.pivotOf(scan.joints.RightHand, goal), nil)
	check("the wrist's transform is unchanged", turnBetween(solution.transforms[3], pose.RightHand) < 1e-6)
end)

case("a point out of reach is reached for as far as the limb goes", function()
	local pose = restPose()
	local placed = Pose.place(scan, pose, identity)
	local hip = (placed.LowerTorso * (Rig.rest(scan.joints.LeftUpperLeg))).Position
	local far = hip + Vector3.new(0, -10, 0)
	local solution, after = solveIn(pose, "LeftFoot", far, nil)
	check("it says how far short it fell", solution.miss > 7 and solution.miss < 9, solution.miss)
	local ankle = Limb.pivotOf(scan.joints.LeftFoot, after.LeftFoot)
	check("the ankle is as low as the leg reaches", ankle.Y < hip.Y - 1.9, ankle.Y - hip.Y)
	check("the miss is the distance left", math.abs((ankle - far).Magnitude - solution.miss) < 1e-4)
end)

case("a pole sets which way the knee points", function()
	local pose = restPose()
	pose.LowerTorso = CFrame.new(0, -0.6, 0)
	local placed = Pose.place(scan, pose, identity)
	local rest = Pose.place(scan, restPose(), identity)
	local pivot = Limb.pivotOf(scan.joints.LeftFoot, rest.LeftFoot)
	for _, side in { -1, 1 } do
		-- A pole out to the side: the knee should splay that way.
		local hip = (placed.LowerTorso * (Rig.rest(scan.joints.LeftUpperLeg))).Position
		local pole = hip + Vector3.new(side * 3, -0.6, -1)
		local solution, after = solveIn(pose, "LeftFoot", pivot, nil, pole)
		check(`reached with the pole at {side}`, solution.miss < 1e-4, solution.miss)
		local knee = (after.LeftUpperLeg * (Rig.rest(scan.joints.LeftLowerLeg))).Position
		local line = (pivot - hip).Unit
		local out = (knee - hip) - line * line:Dot(knee - hip)
		check(`the knee points to the side of the pole at {side}`, out.X * side > 0.05, out.X)
	end
end)

print(`{count - failures}/{count} limb checks passed`)
if failures > 0 then
	process.exit(1)
end
