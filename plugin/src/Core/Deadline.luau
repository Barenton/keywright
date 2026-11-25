--!strict
-- Runs a piece of work with a limit on how long anyone waits for it.
--
-- The work runs in a thread of its own. If it finishes in time, its outcome is returned.
-- If it does not, the caller is told so and moves on; the work is not stopped, because
-- nothing can stop it, but whatever it eventually returns is ignored.
--
-- This is what keeps one request that never returns from holding up every request
-- after it.

local Deadline = {}

export type Kit = {
	spawn: (work: () -> ()) -> (),
	wait: (seconds: number?) -> (),
	clock: () -> number,
}

-- Studio's own, looked up when first needed: the offline tests pass theirs in.
local function studio(): Kit
	return { spawn = task.spawn :: any, wait = task.wait :: any, clock = os.clock }
end

-- Returns whether the work finished within `limit` seconds and, if it did, whether it
-- succeeded and what it returned or raised.
function Deadline.run(limit: number, work: () -> any, kit: Kit?): (boolean, boolean, any)
	local tools = kit or studio()
	local done, ok, result = false, false, nil :: any
	tools.spawn(function()
		ok, result = pcall(work)
		done = true
	end)
	local started = tools.clock()
	while not done do
		if tools.clock() - started >= limit then
			return false, false, nil
		end
		tools.wait()
	end
	return true, ok, result
end

return Deadline
