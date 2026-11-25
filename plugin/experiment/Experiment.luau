--!strict
-- Test build only. Methods for finding out, in Studio, how clips made of curves
-- (CurveAnimation) are laid out and how they play, before Keywright depends on them.
-- They are reached by scripts through the broker, never by the MCP tools. The plugin as
-- released does not contain this module.
--
--   experiment.describe       Lays out a clip: every instance in it, and every key of
--                             every curve with its value, interpolation and tangents.
--                             For learning how the Animation Editor builds one.
--   experiment.curve_sample   Builds a CurveAnimation from a description of its tree,
--                             samples it on the rig at given times, and can save it
--                             where the Animation Editor will list it.
--   experiment.meshes         Opens each part's mesh of the rig as an EditableMesh, to
--                             learn whether a plugin may, how large the meshes are, how
--                             long it takes, and how mesh positions map onto the part.
--                             Can return the geometry, capped, for drawing offline. Every
--                             mesh opened is destroyed before returning.

local AssetService = game:GetService("AssetService")
local ServerStorage = game:GetService("ServerStorage")
local Selection = game:GetService("Selection")

local Experiment = {}

local MAX_NODES = 400
local MAX_KEYS = 200
local MAX_TIMES = 64

local function degrees(cframe: CFrame): { number }
	local x, y, z = cframe:ToEulerAnglesXYZ()
	return { math.deg(x), math.deg(y), math.deg(z) }
end

local function read(instance: any, property: string): any
	local ok, value = pcall(function()
		return instance[property]
	end)
	return if ok then value else nil
end

-- Most vertices of one part's mesh returned as geometry.
local MAX_MESH_VERTICES = 6000

local function vector(value: Vector3): { number }
	return { value.X, value.Y, value.Z }
end

-- Opens one part's mesh and measures it. Never keeps the mesh.
local function measureMesh(part: Instance, geometry: boolean): { [string]: any }
	local entry: { [string]: any } = { part = part.Name, class = part.ClassName }
	local size = read(part, "Size")
	local meshSize = read(part, "MeshSize")
	local content = read(part, "MeshContent")
	entry.size = if typeof(size) == "Vector3" then vector(size) else nil
	entry.mesh_size = if typeof(meshSize) == "Vector3" then vector(meshSize) else nil
	entry.mesh_id = read(part, "MeshId")
	entry.content_type = typeof(content)
	if content == nil then
		entry.status = "no MeshContent"
		return entry
	end
	local started = os.clock()
	local ok, mesh = pcall(function()
		return AssetService:CreateEditableMeshAsync(content)
	end)
	entry.open_ms = math.round((os.clock() - started) * 100000) / 100
	if not ok then
		entry.status = "refused"
		entry.error = tostring(mesh)
		return entry
	end
	entry.status = "opened"
	local readStarted = os.clock()
	local readOk, problem = pcall(function()
		local vertices = mesh:GetVertices()
		local faces = mesh:GetFaces()
		entry.vertices = #vertices
		entry.faces = #faces
		entry.reported_size = vector(mesh:GetSize())
		entry.reported_center = vector(mesh:GetCenter())
		local low = Vector3.new(math.huge, math.huge, math.huge)
		local high = -low
		local index: { [any]: number } = {}
		local positions = {}
		for number, id in vertices do
			local position = mesh:GetPosition(id)
			low = low:Min(position)
			high = high:Max(position)
			index[id] = number - 1
			if geometry and #vertices <= MAX_MESH_VERTICES then
				table.insert(positions, math.round(position.X * 10000) / 10000)
				table.insert(positions, math.round(position.Y * 10000) / 10000)
				table.insert(positions, math.round(position.Z * 10000) / 10000)
			end
		end
		entry.bounds_low = vector(low)
		entry.bounds_high = vector(high)
		if geometry and #vertices <= MAX_MESH_VERTICES then
			local triangles = {}
			for _, face in faces do
				local corners = mesh:GetFaceVertices(face)
				for _, corner in corners do
					table.insert(triangles, index[corner])
				end
			end
			entry.positions = positions
			entry.triangles = triangles
		elseif geometry then
			entry.geometry_omitted = `more than {MAX_MESH_VERTICES} vertices`
		end
	end)
	entry.read_ms = math.round((os.clock() - readStarted) * 100000) / 100
	if not readOk then
		entry.read_error = tostring(problem)
	end
	pcall(function()
		mesh:Destroy()
	end)
	return entry
end

local function describeKey(key: any): { [string]: any }
	local value = read(key, "Value")
	local entry: { [string]: any } = {
		time = read(key, "Time"),
		interpolation = (read(key, "Interpolation") :: any) and read(key, "Interpolation").Name,
		left = read(key, "LeftTangent"),
		right = read(key, "RightTangent"),
	}
	if typeof(value) == "CFrame" then
		entry.rotation = degrees(value)
		entry.position = { value.X, value.Y, value.Z }
	else
		entry.value = value
	end
	return entry
end

local function describe(clip: Instance): { [string]: any }
	local nodes = {}
	local function walk(instance: Instance, path: string)
		for _, child in instance:GetChildren() do
			if #nodes >= MAX_NODES then
				return
			end
			local here = if path == "" then child.Name else `{path}/{child.Name}`
			local node: { [string]: any } = { path = here, class = child.ClassName }
			local ok, keys = pcall(function()
				return (child :: any):GetKeys()
			end)
			if ok and type(keys) == "table" then
				node.key_count = #keys
				node.keys = {}
				for index = 1, math.min(#keys, MAX_KEYS) do
					table.insert(node.keys, describeKey(keys[index]))
				end
			end
			for _, property in { "Weight", "Value", "Time" } do
				local value = read(child, property)
				if type(value) == "number" or type(value) == "string" then
					node[string.lower(property)] = value
				end
			end
			table.insert(nodes, node)
			walk(child, here)
		end
	end
	walk(clip, "")
	return {
		name = clip.Name,
		class = clip.ClassName,
		loop = read(clip, "Loop"),
		priority = (read(clip, "Priority") :: any) and read(clip, "Priority").Name,
		nodes = nodes,
		truncated = if #nodes >= MAX_NODES then true else nil,
	}
end

local function interpolation(name: any): Enum.KeyInterpolationMode
	local mode = (Enum.KeyInterpolationMode :: any)[if type(name) == "string" then name else "Cubic"]
	assert(mode, `unknown interpolation "{tostring(name)}"`)
	return mode
end

-- Builds a clip from nodes, each { path (of its parent, "" for the clip), class, name,
-- keys? }. A FloatCurve's key has a number value; a RotationCurve's has three angles in
-- degrees, applied in X, Y, Z order. Each key may give interpolation, left and right.
local function build(nodes: { any }, loop: boolean?): Instance
	local clip = Instance.new("CurveAnimation")
	clip.Name = "Experiment"
	(clip :: any).Loop = loop == true
	local byPath: { [string]: Instance } = { [""] = clip }
	assert(#nodes <= MAX_NODES, "too many nodes")
	for _, node in nodes do
		local parent = byPath[node.path or ""]
		assert(parent, `no parent at "{tostring(node.path)}"`)
		local instance: any = Instance.new(node.class)
		instance.Name = node.name
		instance.Parent = parent
		byPath[if (node.path or "") == "" then node.name else `{node.path}/{node.name}`] = instance
		for index, key in node.keys or {} do
			assert(index <= MAX_KEYS, "too many keys")
			local made: any
			if node.class == "RotationCurve" then
				local r = key.value
				made = RotationCurveKey.new(
					key.time,
					CFrame.fromEulerAnglesXYZ(math.rad(r[1]), math.rad(r[2]), math.rad(r[3])),
					interpolation(key.interpolation)
				)
			else
				made = FloatCurveKey.new(key.time, key.value, interpolation(key.interpolation))
			end
			if key.left ~= nil then
				made.LeftTangent = key.left
			end
			if key.right ~= nil then
				made.RightTangent = key.right
			end
			instance:InsertKey(made)
		end
	end
	return clip
end

function Experiment.install(methods: { [string]: (params: any) -> any }, kit: any)
	local function rig(params: any): Model
		local model = kit.registry.models[params.rig_id]
		assert(model and model.Parent, "no such rig; call get_workspace first")
		return model
	end

	methods["experiment.describe"] = function(params: any): any
		local clip: Instance?
		if params.source == "selection" then
			clip = Selection:Get()[1]
		else
			local container = kit.Saves.container(rig(params), ServerStorage)
			clip = container and container:FindFirstChild(string.sub(tostring(params.source), 7))
		end
		assert(clip, "no clip found")
		return describe(clip :: Instance)
	end

	methods["experiment.meshes"] = function(params: any): any
		local model = rig(params)
		local wanted: { [string]: boolean }? = nil
		if type(params.parts) == "table" then
			wanted = {}
			for _, name in params.parts do
				(wanted :: { [string]: boolean })[name] = true
			end
		end
		local parts = {}
		local started = os.clock()
		for _, child in model:GetChildren() do
			if child:IsA("BasePart") and (not wanted or wanted[child.Name]) then
				table.insert(parts, measureMesh(child, params.geometry == true))
			end
		end
		table.sort(parts, function(a, b)
			return a.part < b.part
		end)
		return { parts = parts, total_ms = math.round((os.clock() - started) * 100000) / 100 }
	end

	methods["experiment.curve_sample"] = function(params: any): any
		local model = rig(params)
		local scan = kit.Rig.require(model)
		local clip = build(params.nodes, params.loop)
		local joints: { string } = params.joints or {}
		local samples = {}
		assert(#(params.times or {}) <= MAX_TIMES, "too many times")
		for _, time in params.times or {} do
			local preview = kit.Preview.run({
				model = model,
				sequence = clip,
				time = time,
				joints = joints,
				parent = workspace,
			})
			local at = { time = time, joints = {} }
			for _, name in joints do
				local cframe = preview.transforms[name]
				if cframe then
					at.joints[name] = { rotation = degrees(cframe), position = { cframe.X, cframe.Y, cframe.Z } }
				end
			end
			table.insert(samples, at)
		end
		local saved = nil
		if type(params.save_as) == "string" then
			local recording = kit.Recording.begin("KeywrightExperiment", "Keywright experiment save")
			local ok, problem = pcall(kit.Saves.save, clip, model, ServerStorage, params.save_as, function(className)
				return Instance.new(className)
			end)
			kit.Recording.finish(recording, ok)
			assert(ok, problem)
			saved = params.save_as
		end
		local description = describe(clip)
		clip:Destroy()
		return { samples = samples, saved = saved, built = description, joints_known = scan.joints ~= nil }
	end
end

return Experiment
