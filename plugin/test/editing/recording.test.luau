--!strict
-- Offline tests for the undo-recording bookkeeping and for the test build's faults.
-- Run with: lune run plugin/test/editing/recording.test.luau
--
-- Studio's undo history is replaced by a stand-in that allows one open recording at a
-- time. Not tested here, and not knowable offline: what Studio does to the place when a
-- recording is cancelled, and what it does with a recording that is never finished.

local process = require("@lune/process")

local Fault = require("../../fault/Fault")
local Recording = require("../../src/Editing/Recording")

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
	Recording.abandon()
	local ok, problem = pcall(run)
	if not ok then
		count += 1
		failures += 1
		print(
			`FAIL [{name}] raised: {if type(problem) == "table" then (problem :: any).message else tostring(problem)}`
		)
	end
end

-- An undo history that allows one open recording, and remembers how each one ended.
local function history()
	local state = { open = nil :: string?, started = 0, committed = {} :: { string }, cancelled = {} :: { string } }
	Recording.history = {
		begin = function(_name: string, _displayName: string): string?
			if state.open then
				return nil
			end
			state.started += 1
			state.open = `recording {state.started}`
			return state.open
		end,
		finish = function(identifier: string, commit: boolean)
			assert(state.open == identifier, "finished a recording that is not open")
			state.open = nil
			table.insert(if commit then state.committed else state.cancelled, identifier)
		end,
	}
	return state
end

local function raised(run: () -> ()): any
	local ok, problem = pcall(run)
	return if ok then nil else problem
end

case("a finished recording is committed and leaves nothing open", function()
	local state = history()
	local id = Recording.begin("Name", "Display")
	check("open while recording", Recording.isOpen())
	Recording.finish(id, true)
	check("committed", state.committed[1] == id and #state.cancelled == 0)
	check("nothing open afterwards", not Recording.isOpen() and state.open == nil)
	check("nothing to abandon", Recording.abandon() == false)
end)

case("a failed change cancels its recording", function()
	local state = history()
	local id = Recording.begin("Name", "Display")
	Recording.finish(id, false)
	check("cancelled", state.cancelled[1] == id and #state.committed == 0)
	check("the next recording starts", Recording.begin("Name", "Display") == "recording 2")
end)

case("a recording left open is cancelled when abandoned", function()
	local state = history()
	local id = Recording.begin("Name", "Display")
	check("abandon reports it", Recording.abandon() == true)
	check("cancelled, not committed", state.cancelled[1] == id and #state.committed == 0)
	check("nothing open afterwards", not Recording.isOpen() and state.open == nil)
	check("abandoning twice does nothing", Recording.abandon() == false and #state.cancelled == 1)
end)

case("a second recording is refused while the first is open", function()
	local state = history()
	local id = Recording.begin("Name", "Display")
	local problem = raised(function()
		Recording.begin("Name", "Display")
	end)
	check("refused", type(problem) == "table" and problem.code == "STUDIO_NOT_IN_EDIT_MODE")
	check("says the earlier change is the cause", string.find(problem.message, "earlier Keywright change") ~= nil)
	check("the first is still the open one", state.open == id and Recording.isOpen())
	Recording.finish(id, true)
	check("the first still commits", state.committed[1] == id)
end)

case("a refusal that is not ours points at what Studio has in progress", function()
	local state = history()
	state.open = "someone else's"
	local problem = raised(function()
		Recording.begin("Name", "Display")
	end)
	check("refused", type(problem) == "table" and problem.code == "STUDIO_NOT_IN_EDIT_MODE")
	check("hint says to finish what is in progress", string.find(problem.hint, "in progress in Studio") ~= nil)
	check("nothing of ours is open", not Recording.isOpen())
	check("nothing to abandon", Recording.abandon() == false and state.open == "someone else's")
end)

case("an abandon that Studio rejects does not raise", function()
	history()
	Recording.begin("Name", "Display");
	(Recording.history :: any).finish = function()
		error("Studio said no")
	end
	check("abandon still reports it", Recording.abandon() == true)
	check("and forgets it", not Recording.isOpen())
end)

-- The test build's faults, driven the way Edit drives its hook: a recording is begun,
-- the hook is called before each operation, and the recording is finished by the result.
local function batch(name: string, operations: number, hook: any): (boolean, number)
	local applied = 0
	local id = Recording.begin("Name", "Display")
	local ok = pcall(function()
		for index = 1, operations do
			if hook then
				hook({ instance = { Name = name } }, index)
			end
			applied += 1
		end
	end)
	Recording.finish(id, ok)
	return ok, applied
end

local function installed(): (any, { stalls: number })
	local edit = {} :: any
	local seen = { stalls = 0 }
	Fault.install(edit, Recording, function()
		seen.stalls += 1
		error("stalled", 0)
	end)
	return edit, seen
end

case("the test build leaves other clips alone", function()
	local state = history()
	local edit = installed()
	local ok, applied = batch("Cheer", 3, edit.fault)
	check("the batch succeeds whole", ok and applied == 3)
	check("committed", #state.committed == 1 and #state.cancelled == 0)
end)

case("the test build fails a batch after its first operation", function()
	local state = history()
	local edit = installed()
	local ok, applied = batch(Fault.FAIL, 3, edit.fault)
	check("the batch fails", not ok)
	check("after exactly one operation", applied == 1, applied)
	check("its recording is cancelled", #state.cancelled == 1 and #state.committed == 0)
	local single, one = batch(Fault.FAIL, 1, edit.fault)
	check("a one-operation batch succeeds", single and one == 1)
end)

case("the test build stalls a batch after its first operation", function()
	history()
	local edit, seen = installed()
	local _, applied = batch(Fault.STALL, 2, edit.fault)
	check("stalled once, after one operation", seen.stalls == 1 and applied == 1)
	local id = Recording.begin("Name", "Display")
	check("unload still cancels an open recording", Recording.abandon() == true)
	check("so the next one starts", Recording.begin("Name", "Display") ~= id)
end)

case("the raw stall stops the plugin cancelling on unload", function()
	local state = history()
	local edit, seen = installed()
	local abandon = Recording.abandon
	batch(Fault.STALL_RAW, 2, edit.fault)
	check("stalled", seen.stalls == 1)
	local id = Recording.begin("Name", "Display")
	check("unload cancels nothing", Recording.abandon() == false)
	check("the recording stays open", state.open == id)
	Recording.abandon = abandon
end)

print(`{count - failures} of {count} checks passed`)
if failures > 0 then
	process.exit(1)
end
