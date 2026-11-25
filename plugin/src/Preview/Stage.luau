--!strict
-- Proof that a camera, as a person left it, already shows a given subject whole.
--
-- Nothing here moves, frames or otherwise writes to a camera, and nothing here reads
-- Studio: every function only computes from the values it is handed. A screenshot is
-- allowed only when this proof succeeds; when it does not, the answer is the reason.
--
-- A subject is a sphere, or several. Each is proved to lie entirely inside the camera's
-- view: in front of the camera and beyond its near plane, and clear of all four edges of
-- the picture. The subject as a whole must also be close enough to be seen and large
-- enough to be the thing the picture is of. The camera must be the right way up, and its
-- field of view and the viewport's size must be ordinary values.
--
-- What this cannot prove is that nothing stands between the camera and the subject, or
-- that Studio renders what these numbers describe. Those are for whoever calls this.

local Stage = {}

-- A camera as observed: where it is, its vertical field of view in degrees, and the
-- size of the viewport in pixels.
export type View = {
	cframe: CFrame,
	fieldOfView: number,
	width: number,
	height: number,
}

export type Subject = {
	centre: Vector3,
	radius: number,
}

Stage.MIN_FIELD_OF_VIEW = 20
Stage.MAX_FIELD_OF_VIEW = 90
Stage.MIN_EDGE = 64
Stage.MAX_EDGE = 8192
-- Largest sideways tilt allowed, as the vertical part of the camera's right-hand direction.
Stage.MAX_ROLL = 0.02
-- Steepest the camera may point up or down, as the vertical part of its direction (about
-- 60 degrees). Beyond this, sideways tilt can no longer be told from turning.
Stage.MAX_PITCH = 0.87
-- Furthest the camera may be from the subject, in studs.
Stage.MAX_DISTANCE = 200
-- Nearest any part of a subject may come to the camera, in studs, to stay beyond the
-- distance at which Studio stops drawing.
Stage.NEAR = 1
-- Smallest share of the narrower half-angle of the picture that the subject must span.
Stage.MIN_FILL = 0.2
-- How far two observations of a camera may differ and still be the same view.
Stage.POSITION_TOLERANCE = 0.001
Stage.DIRECTION_TOLERANCE = 0.999999

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function whole(value: any): boolean
	return finite(value) and value == math.floor(value)
end

-- Returns nil when the view's own values can be used, or the reason they cannot.
function Stage.usable(view: View): string?
	if not finite(view.fieldOfView) then
		return "the camera's field of view cannot be read"
	elseif view.fieldOfView < Stage.MIN_FIELD_OF_VIEW or view.fieldOfView > Stage.MAX_FIELD_OF_VIEW then
		return `the camera's field of view is {view.fieldOfView} degrees, outside {Stage.MIN_FIELD_OF_VIEW} to {Stage.MAX_FIELD_OF_VIEW}`
	elseif not whole(view.width) or not whole(view.height) then
		return "the viewport's size cannot be read"
	elseif
		view.width < Stage.MIN_EDGE
		or view.height < Stage.MIN_EDGE
		or view.width > Stage.MAX_EDGE
		or view.height > Stage.MAX_EDGE
	then
		return `the viewport is {view.width} by {view.height} pixels, outside {Stage.MIN_EDGE} to {Stage.MAX_EDGE}`
	end
	local right = view.cframe.RightVector
	if not finite(right.Y) or not finite(view.cframe.Position.Magnitude) then
		return "the camera's position cannot be read"
	elseif not (math.abs(view.cframe.LookVector.Y) <= Stage.MAX_PITCH) then
		return "the camera is pointed too steeply up or down"
	elseif math.abs(right.Y) > Stage.MAX_ROLL then
		return "the camera is tilted sideways"
	elseif view.cframe.UpVector.Y <= 0 then
		return "the camera is upside down"
	end
	return nil
end

-- Returns nil when one sphere is provably whole inside the picture, or the reason not.
-- The view is assumed usable.
local function inside(view: View, subject: Subject): string?
	if not finite(subject.radius) or subject.radius <= 0 or not finite(subject.centre.Magnitude) then
		return "the subject has no usable size"
	end
	local offset = subject.centre - view.cframe.Position
	local across = offset:Dot(view.cframe.RightVector)
	local up = offset:Dot(view.cframe.UpVector)
	local depth = offset:Dot(view.cframe.LookVector)
	if depth <= subject.radius then
		return "the subject is not in front of the camera"
	elseif depth - subject.radius < Stage.NEAR then
		return "the subject is too close to the camera"
	end
	local halfVertical = math.rad(view.fieldOfView) / 2
	local halfHorizontal = math.atan(math.tan(halfVertical) * view.width / view.height)
	-- Distance from the sphere's centre to each edge of the picture must exceed its radius.
	if depth * math.sin(halfVertical) - math.abs(up) * math.cos(halfVertical) < subject.radius then
		return "the subject is not wholly inside the top and bottom of the picture"
	elseif depth * math.sin(halfHorizontal) - math.abs(across) * math.cos(halfHorizontal) < subject.radius then
		return "the subject is not wholly inside the sides of the picture"
	end
	return nil
end

-- Returns nil when every one of the spheres is provably whole inside the picture, or the
-- reason one is not. An empty list proves nothing and is refused.
function Stage.holds(view: View, subjects: { Subject }): string?
	local problem = Stage.usable(view)
	if problem then
		return problem
	end
	if #subjects == 0 then
		return "there is nothing to show"
	end
	for _, subject in subjects do
		local outside = inside(view, subject)
		if outside then
			return outside
		end
	end
	return nil
end

-- Returns nil when the subject is provably whole in the picture, near enough and large
-- enough to be what the picture is of, or the reason it is not.
function Stage.framed(view: View, subject: Subject): string?
	local problem = Stage.usable(view) or inside(view, subject)
	if problem then
		return problem
	end
	local distance = (subject.centre - view.cframe.Position).Magnitude
	if distance > Stage.MAX_DISTANCE then
		return "the camera is too far from the subject"
	end
	local halfVertical = math.rad(view.fieldOfView) / 2
	local halfHorizontal = math.atan(math.tan(halfVertical) * view.width / view.height)
	if math.asin(subject.radius / distance) < Stage.MIN_FILL * math.min(halfVertical, halfHorizontal) then
		return "the subject is too small in the picture"
	end
	return nil
end

-- True when two observations show the same camera view: position, direction, tilt,
-- field of view and viewport size.
function Stage.same(first: View, second: View): boolean
	local ok, same = pcall(function()
		return (first.cframe.Position - second.cframe.Position).Magnitude <= Stage.POSITION_TOLERANCE
			and first.cframe.LookVector:Dot(second.cframe.LookVector) >= Stage.DIRECTION_TOLERANCE
			and first.cframe.UpVector:Dot(second.cframe.UpVector) >= Stage.DIRECTION_TOLERANCE
			and first.fieldOfView == second.fieldOfView
			and first.width == second.width
			and first.height == second.height
	end)
	return ok and same == true
end

return Stage
