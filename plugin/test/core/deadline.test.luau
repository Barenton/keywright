--!strict
-- Offline tests for running work against a time limit. Run with: lune run plugin/test/core/deadline.test.luau
--
-- Real here: Lune's own threads and clock. Not tested here: the plugin's request queue
-- that uses this, which needs Studio's connection to a broker.

local process = require("@lune/process")
local task = require("@lune/task")

local Deadline = require("../../src/Core/Deadline")

local kit = { spawn = task.spawn :: any, wait = task.wait :: any, clock = os.clock }

local failures = 0
local count = 0

local function check(name: string, condition: any, detail: any?)
	count += 1
	if not condition then
		failures += 1
		print(`FAIL {name}{if detail ~= nil then ": " .. tostring(detail) else ""}`)
	end
end

local finished, ok, result = Deadline.run(1, function()
	return "done"
end, kit)
check("work that returns at once is finished, with its result", finished and ok and result == "done")

finished, ok, result = Deadline.run(1, function()
	task.wait(0.05)
	return 42
end, kit)
check("work that waits a little is waited for", finished and ok and result == 42)

finished, ok, result = Deadline.run(1, function()
	error({ code = "INVALID_ARGUMENT" })
end, kit)
check("work that fails is finished, with what it raised", finished and not ok and result.code == "INVALID_ARGUMENT")

local late = false
local started = os.clock()
finished, ok, result = Deadline.run(0.1, function()
	task.wait(0.4)
	late = true
	return "too late"
end, kit)
local waited = os.clock() - started
check("work that overruns is given up on", not finished and result == nil)
check("at the limit, not when the work ends", waited >= 0.1 and waited < 0.3, waited)
check("the work itself is not stopped", not late)

-- The next piece of work is not held up by the one still running.
finished, ok, result = Deadline.run(1, function()
	return "next"
end, kit)
check("the next work runs straight away", finished and result == "next" and not late)
task.wait(0.5)
check("and the overrun work ends by itself, its result ignored", late)

finished = Deadline.run(0.05, function()
	coroutine.yield()
end, kit)
check("work that never returns is given up on too", not finished)

print(`{count - failures}/{count} deadline checks passed`)
if failures > 0 then
	process.exit(1)
end
