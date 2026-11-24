--!strict
-- Undo recordings. Every change the plugin makes to the place happens inside one, so
-- that one Studio undo reverts it.
--
-- Studio gives a plugin one open recording at a time, and a recording that is never
-- finished refuses every later one. This module therefore remembers which recording is
-- open, so that it can be cancelled when the plugin unloads.
--
-- Studio's undo history is reached through `Recording.history`, which is looked up on
-- first use, so that the bookkeeping here can be tested without Studio. What Studio does
-- when a recording is cancelled is not decided here and is not documented by Roblox.

local Errors = require("./Errors")

local Recording = {}

export type History = {
	-- Returns the new recording's identifier, or nil when Studio refuses to start one.
	begin: (name: string, displayName: string) -> string?,
	finish: (identifier: string, commit: boolean) -> (),
}

Recording.history = nil :: History?

local open: string? = nil

local function studio(): History
	local service = game:GetService("ChangeHistoryService")
	return {
		begin = function(name: string, displayName: string): string?
			return service:TryBeginRecording(name, displayName)
		end,
		finish = function(identifier: string, commit: boolean)
			service:FinishRecording(
				identifier,
				if commit then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
			)
		end,
	}
end

local function history(): History
	local current = Recording.history
	if not current then
		current = studio()
		Recording.history = current
	end
	return current :: History
end

-- Starts a recording and returns its identifier. Raises when Studio refuses.
function Recording.begin(name: string, displayName: string): string
	local identifier = history().begin(name, displayName)
	if not identifier then
		if open then
			Errors.throw(
				"STUDIO_NOT_IN_EDIT_MODE",
				"Studio could not start an undo recording: an earlier Keywright change has not finished.",
				"Wait for the earlier change, or reload the plugin if it never finishes."
			)
		end
		Errors.throw(
			"STUDIO_NOT_IN_EDIT_MODE",
			"Studio could not start an undo recording.",
			"Close the Animation Editor if it is open, stop any playtest, and retry."
		)
	end
	open = identifier
	return identifier :: string
end

-- Finishes a recording: kept as one undo step when `commit` is true, cancelled otherwise.
function Recording.finish(identifier: string, commit: boolean)
	history().finish(identifier, commit)
	if open == identifier then
		open = nil
	end
end

-- Cancels the recording that is still open, if there is one. Returns whether there was.
-- For when the plugin unloads: nothing else will ever finish that recording.
function Recording.abandon(): boolean
	local identifier = open
	if not identifier then
		return false
	end
	open = nil
	pcall(history().finish, identifier, false)
	return true
end

function Recording.isOpen(): boolean
	return open ~= nil
end

return Recording
