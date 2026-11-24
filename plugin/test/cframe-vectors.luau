--!strict
-- Prints the E10 CFrame vectors as computed by Lune's Roblox datatypes, as JSON.
-- The E10 parity check compares this output with the same vectors computed in Studio,
-- which needs a person in Studio and has not been done.

local roblox = require("@lune/roblox") :: any
local serde = require("@lune/serde")

local vectors = require("../probe/CFrameVectors")(roblox.CFrame, roblox.Vector3)
print(serde.encode("json", vectors))
