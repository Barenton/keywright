--!strict
-- Test build only. Makes an edit go wrong partway through, so that what Studio does with
-- a cancelled or abandoned undo recording can be checked in a throwaway place. The
-- plugin as released does not contain this module.
--
-- Which fault happens is chosen by the name of the working copy being edited. In each
-- case the first operation of the batch is applied and the fault comes before the second:
--
--   "Fault fail"       the batch raises an error, so its recording is cancelled.
--   "Fault stall"      the batch never finishes, so its recording stays open until the
--                      plugin unloads and cancels it.
--   "Fault stall raw"  as above, but the plugin does not cancel it on unload either, to
--                      show what Studio does with a recording nobody finishes.
--
-- Edits to a working copy with any other name behave as usual.
--
-- Settings can fail too. While the place has anything named "Fault settings" directly in
-- Workspace, every write to the plugin's settings is dropped without an error, as Studio
-- may do when several windows write at once. Reads still work.

local Fault = {}

Fault.FAIL = "Fault fail"
Fault.STALL = "Fault stall"
Fault.STALL_RAW = "Fault stall raw"
Fault.SETTINGS = "Fault settings"

-- `stall` suspends the calling thread for good; a test passes its own.
function Fault.install(Edit: any, Recording: any, stall: (() -> ())?)
	local suspend: () -> () = stall or coroutine.yield
	Edit.fault = function(working: any, index: number)
		if index < 2 then
			return
		end
		local name = working.instance.Name
		if name == Fault.FAIL then
			error("test build: this batch fails on purpose after its first operation", 0)
		elseif name == Fault.STALL then
			suspend()
		elseif name == Fault.STALL_RAW then
			Recording.abandon = function(): boolean
				return false
			end
			suspend()
		end
	end
end

-- Wraps the plugin's settings store. `active` says whether writes are dropped now; a test
-- passes its own.
function Fault.settings(store: any, active: (() -> boolean)?): any
	local dropping: () -> boolean = active
		or function(): boolean
			return workspace:FindFirstChild(Fault.SETTINGS) ~= nil
		end
	local wrapped = table.clone(store)
	wrapped.set = function(key: string, value: any)
		if not dropping() then
			store.set(key, value)
		end
	end
	return wrapped
end

return Fault
