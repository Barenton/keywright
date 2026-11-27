--!strict
-- Clips made of curves (CurveAnimation): their layout, the edits that can be made to
-- them, and reading, checking and fingerprinting them.
--
-- The layout is the one Roblox's Animation Editor writes, as measured in Studio. The clip
-- holds a Folder for each part of the rig, nested as the parts are, starting from the
-- root part. A joint's Folder holds a Vector3Curve named Position and an
-- EulerRotationCurve named Rotation, and each of those holds three FloatCurves named X,
-- Y and Z. Rotation is in radians, applied in X, Y, Z order. A channel that never moves
-- has no keys. Each marker name is a MarkerCurve at the top of the clip.
--
-- A key has a time, a value and an interpolation: Constant holds its value until the
-- next key, Linear goes straight to it, Cubic follows a curve set by this key's outgoing
-- tangent and the next key's incoming one. Tangents are in value per second; Studio
-- plays a cubic stretch as the standard Hermite curve (measured to 0.08 degrees).
--
-- Studio does not play the curves exactly. It samples them 30 times a second on the
-- clip's own clock (0, 1/30, 2/30 seconds and so on) and goes in straight lines between
-- those samples (measured). A key between two of those frames is never shown exactly,
-- so keys belong on whole frames, and checking a clip says when one is not.
--
-- To the outside, rotations are in degrees and rotation tangents in degrees per second,
-- as everywhere else in Keywright.
--
-- Keys are read and written through `Store.backend` (CurveEdit/Store), which is Studio's own
-- methods in the plugin and a stand-in in the offline tests. The operations themselves are
-- in CurveEdit, a module for each family, each with how it is checked and applied.

local Frames = require("./CurveEdit/Frames")
local ClipOps = require("./CurveEdit/ClipOps")
local AimOp = require("./CurveEdit/AimOp")
local Contacts = require("./CurveEdit/Contacts")
local Convert = require("./CurveEdit/Convert")
local Errors = require("../Core/Errors")
local FloorOps = require("./CurveEdit/FloorOps")
local KeyOps = require("./CurveEdit/KeyOps")
local LayerOps = require("./CurveEdit/LayerOps")
local MirrorOp = require("./CurveEdit/MirrorOp")
local Need = require("./CurveEdit/Need")
local OverlapOp = require("./CurveEdit/OverlapOp")
local PinOp = require("./CurveEdit/PinOp")
local NudgeOp = require("./CurveEdit/NudgeOp")
local Read = require("./CurveEdit/Read")
local Seam = require("./CurveEdit/Seam")
local Store = require("./CurveEdit/Store")
local TimeOps = require("./CurveEdit/TimeOps")

export type Key = Store.Key
export type Marker = Store.Marker
export type Backend = Store.Backend
export type Track = Store.Track
export type Context = Frames.Context
export type Changed = Frames.Changed
export type ReadOptions = Read.ReadOptions

local Curves = {}

-- The limits and names, and how curves are found, read, written and played.
Curves.TIME_TOLERANCE = Store.TIME_TOLERANCE
Curves.FRAME_RATE = Store.FRAME_RATE
Curves.MAX_TIME = Store.MAX_TIME
Curves.MAX_POSITION = Store.MAX_POSITION
Curves.MAX_KEYS = Store.MAX_KEYS
Curves.MAX_OPERATIONS = Store.MAX_OPERATIONS
Curves.MAX_SNAPS = Store.MAX_SNAPS
Curves.MAX_JOINTS = Store.MAX_JOINTS
Curves.MAX_NAME = Store.MAX_NAME
Curves.MAX_MARKER_VALUE = Store.MAX_MARKER_VALUE
Curves.MAX_BLEND = Store.MAX_BLEND
Curves.HOLDS = Store.HOLDS
Curves.PIVOTS = Store.PIVOTS
Curves.FLOOR_MODES = Store.FLOOR_MODES
Curves.MIRROR_MODES = Store.MIRROR_MODES
Curves.MIN_SCALE = Store.MIN_SCALE
Curves.REDUCE_DEGREES = Store.REDUCE_DEGREES
Curves.REDUCE_STUDS = Store.REDUCE_STUDS
Curves.MAX_REDUCE = Store.MAX_REDUCE
Curves.MIN_FREQUENCY = Store.MIN_FREQUENCY
Curves.MAX_FREQUENCY = Store.MAX_FREQUENCY
Curves.MAX_NOISE_DEGREES = Store.MAX_NOISE_DEGREES
Curves.MAX_NOISE_STUDS = Store.MAX_NOISE_STUDS
Curves.MIN_LAG = Store.MIN_LAG
Curves.MAX_LAG = Store.MAX_LAG
Curves.MAX_BOUNCE = Store.MAX_BOUNCE
Curves.MAX_SCALE = Store.MAX_SCALE
Curves.MAX_LISTED = Store.MAX_LISTED
Curves.DEFAULT_KEYS = Store.DEFAULT_KEYS
Curves.MAX_PAGE = Store.MAX_PAGE
Curves.PRIORITIES = Store.PRIORITIES
Curves.INTERPOLATIONS = Store.INTERPOLATIONS
Curves.CHANNELS = Store.CHANNELS
Curves.isCurves = Store.isCurves
Curves.folder = Store.folder
Curves.channel = Store.channel
Curves.tracks = Store.tracks
Curves.markerCurves = Store.markerCurves
Curves.keys = Store.keys
Curves.setKeys = Store.setKeys
Curves.evaluate = Store.evaluate
Curves.SAMPLED = Store.SAMPLED
Curves.duration = Store.duration
Curves.keyTimes = Store.keyTimes

-- Every operation for curve clips, by name: how it is checked and how it is applied, and
-- whether its range may run across a looping clip's end.
type Operation = {
	check: (where: string, operation: any, joints: { [string]: any }) -> (),
	apply: (where: string, clip: Instance, operation: any, context: Context, changed: Changed) -> (),
	wraps: boolean?,
}
local operations: { [string]: Operation } = {}
for _, family in { KeyOps, ClipOps, TimeOps, MirrorOp, PinOp, NudgeOp, FloorOps, LayerOps, AimOp, OverlapOp } :: { any } do
	for name, operation in family do
		operations[name] = operation
	end
end

function Curves.types(): { string }
	local names = {}
	for name in operations do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

function Curves.check(operations_: any, joints: { [string]: any })
	if type(operations_) ~= "table" or #operations_ == 0 then
		Errors.throw("INVALID_ARGUMENT", "operations must be a non-empty list.")
	end
	if #operations_ > Store.MAX_OPERATIONS then
		Errors.throw("LIMIT_EXCEEDED", `A batch holds at most {Store.MAX_OPERATIONS} operations.`)
	end
	for index, operation in operations_ do
		local where = `operations[{index}]`
		if type(operation) ~= "table" then
			Need.refuse(where, "is not an object.")
		end
		local found = if type(operation.type) == "string" then operations[operation.type] else nil
		if not found then
			Need.refuse(
				where,
				`"{tostring(operation.type)}" cannot be used on a clip made of curves.`,
				`The types for curve clips are: {table.concat(Curves.types(), ", ")}.`
			)
		end
		(found :: Operation).check(where, operation, joints)
	end
end

function Curves.run(clip: Instance, list: { any }, context: Context, before: ((index: number) -> ())?): Changed
	local changed: Changed = {}
	for index, operation in list do
		if before then
			before(index)
		end
		local found = operations[operation.type]
		local where = `operations[{index}]`
		if found.wraps then
			Seam.apply(where, clip, operation, context, changed, found.apply)
		else
			found.apply(where, clip, operation, context, changed)
		end
	end
	return changed
end

Curves.fromKeyframes = Convert.fromKeyframes
Curves.read = Read.read
Curves.digestLines = Read.digestLines
Curves.validate = Contacts.validate

return Curves
