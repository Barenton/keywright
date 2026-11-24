--!strict
-- A fixed set of CFrame computations, evaluated once in Studio and once under Lune.
-- Comparing the two outputs is the E10 parity check. Takes the datatype libraries as
-- arguments so the same file runs in both runtimes.

return function(CFrameLib: any, Vector3Lib: any): { { name: string, values: { number } } }
	local results = {}

	local function record(name: string, cframe: any)
		table.insert(results, { name = name, values = { cframe:GetComponents() } })
	end

	local angles = {
		{ 0, 0, 0 },
		{ 0.5, 0, 0 },
		{ 0, -1.2, 0 },
		{ 0, 0, 2.9 },
		{ 0.3, 0.7, -1.1 },
		{ -2.4, 1.3, 0.2 },
		{ 1.5707963267948966, 0.4, 0.4 },
		{ 0.1, 1.5607963267948966, -0.3 },
	}
	local offsets = { { 0, 0, 0 }, { 1.25, -3.5, 0.125 }, { -100.03, 42.7, 999.9 } }

	for i, a in angles do
		local rotation = CFrameLib.fromEulerAnglesXYZ(a[1], a[2], a[3])
		record(`euler_xyz_{i}`, rotation)
		local rx, ry, rz = rotation:ToEulerAnglesXYZ()
		table.insert(results, { name = `to_euler_xyz_{i}`, values = { rx, ry, rz } })
		for j, o in offsets do
			local composed = CFrameLib.new(o[1], o[2], o[3]) * rotation
			record(`compose_{i}_{j}`, composed)
			record(`inverse_{i}_{j}`, composed:Inverse())
		end
	end

	local from = CFrameLib.new(1, 2, 3) * CFrameLib.fromEulerAnglesXYZ(0.2, -0.4, 0.9)
	local to = CFrameLib.new(-4, 0.5, 7) * CFrameLib.fromEulerAnglesXYZ(-1.1, 0.8, 2.2)
	for _, alpha in { 0, 0.1, 0.25, 0.5, 0.75, 0.9, 1 } do
		record(`lerp_{alpha}`, from:Lerp(to, alpha))
	end

	-- A three-joint chain, the shape forward kinematics takes.
	local chain = from * CFrameLib.new(0, -0.6, 0) * to * CFrameLib.new(0, 0.6, 0):Inverse() * from:Inverse()
	record("chain", chain)
	local point = chain * Vector3Lib.new(0.5, -1.5, 2)
	table.insert(results, { name = "point", values = { point.X, point.Y, point.Z } })

	return results
end
