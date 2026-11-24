--!strict
-- Prints the E10 CFrame vectors as computed by Lune's Roblox datatypes, as JSON.
-- These were meant to be compared with the same vectors computed in Studio by the probe,
-- which was never run. The comparison with Studio is done another way, through the
-- ordinary tools: see vectors.luau.

local roblox = require("@lune/roblox") :: any
local serde = require("@lune/serde")

local vectors = require("../probe/CFrameVectors")(roblox.CFrame, roblox.Vector3)
print(serde.encode("json", vectors))
