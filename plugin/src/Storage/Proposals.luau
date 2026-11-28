--!strict
-- Proposals a person settles in the Studio panel: to replace a clip with the working copy
-- that was opened from it, or to delete one of a rig's saved clips.
--
-- An agent can only propose. A proposal is settled by a person in the Studio panel, or
-- falls away when the working copy is discarded. This module holds the proposals and
-- nothing else: it touches no instance and decides nothing.
--
-- A working copy has at most one proposal, for one revision of it. Proposing the same
-- revision again returns the proposal as it stands, so that asking twice neither asks
-- the person twice nor overturns what they decided.

local Proposals = {}

export type Status = "pending" | "approved" | "rejected"
export type Kind = "replace" | "delete"

export type Proposal = {
	-- What it is about: a working copy's id, or for a deletion "delete:", the rig's id and
	-- the clip's name.
	clipId: string,
	-- For a replacement, the working copy's revision; for a deletion, the fingerprint of
	-- the saved clip, which must still be the same when it is approved.
	revision: string,
	kind: Kind,
	status: Status,
	-- Why it was rejected, when it was.
	reason: string?,
	-- Names for the panel: the working copy and the clip it would replace; or the saved
	-- clip to delete and its rig.
	name: string,
	source: string,
	order: number,
}

local byClip: { [string]: Proposal } = {}
local listeners: { [() -> ()]: boolean } = {}
local counter = 0

local function changed()
	for listener in listeners do
		-- One listener failing must not keep the others from hearing.
		pcall(listener)
	end
end

-- Calls `listener` whenever any proposal is made, settled or forgotten. Returns a
-- function that stops it.
function Proposals.subscribe(listener: () -> ()): () -> ()
	listeners[listener] = true
	return function()
		listeners[listener] = nil
	end
end

function Proposals.get(clipId: string): Proposal?
	return byClip[clipId]
end

-- The proposal for this revision of the working copy, made now if there is none. An
-- earlier proposal for another revision is dropped: the clip it was about no longer
-- exists in that form. Returns the proposal and whether it was made by this call.
function Proposals.propose(
	clipId: string,
	revision: string,
	name: string,
	source: string,
	kind: Kind?
): (Proposal, boolean)
	local existing = byClip[clipId]
	if existing and existing.revision == revision then
		return existing, false
	end
	counter += 1
	local proposal: Proposal = {
		clipId = clipId,
		revision = revision,
		kind = kind or "replace",
		status = "pending",
		name = name,
		source = source,
		order = counter,
	}
	byClip[clipId] = proposal
	changed()
	return proposal, true
end

-- Proposals still waiting for a person, oldest first.
function Proposals.pending(): { Proposal }
	local list = {}
	for _, proposal in byClip do
		if proposal.status == "pending" then
			table.insert(list, proposal)
		end
	end
	table.sort(list, function(a, b)
		return a.order < b.order
	end)
	return list
end

-- Settles a waiting proposal. Returns it, or nil if there was none waiting: a proposal
-- is settled once.
function Proposals.settle(clipId: string, approved: boolean, reason: string?): Proposal?
	local proposal = byClip[clipId]
	if not proposal or proposal.status ~= "pending" then
		return nil
	end
	proposal.status = if approved then "approved" else "rejected"
	proposal.reason = if approved then nil else reason
	changed()
	return proposal
end

-- Drops whatever proposal the working copy has, as when it is discarded.
function Proposals.forget(clipId: string)
	if byClip[clipId] then
		byClip[clipId] = nil
		changed()
	end
end

return Proposals
