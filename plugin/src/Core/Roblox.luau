--!strict
-- The engine's own libraries, gathered in one table.
--
-- Modules that must also run in the offline tests take these from here, at the moment
-- they need them, instead of from globals. A test puts Lune's versions in their place
-- before anything uses them. Inside Studio this table is simply the globals.

local Roblox = {
	Instance = Instance,
	CFrame = CFrame,
	Enum = Enum,
	-- The place's Workspace: a rig must be somewhere under it.
	Workspace = workspace :: Instance,
}

return Roblox
