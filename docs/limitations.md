# Limitations

What Keywright doesn't do, or doesn't do yet, and what has not been tried.

## Where it runs

- **Studio on Windows only, so far.** macOS should work, but nobody has tried it yet.
- **WSL's default networking.** Running the AI app and adapter inside WSL works with WSL's default (NAT) networking. Mirrored networking hasn't been tried.
- **AI apps.** Keywright has been used fully from Claude Code. Claude Desktop and Codex have connected and shown a pose picture, but haven't been through a whole animation.
- **Built from source.** There is no npm package, app bundle or Creator Store plugin yet. Setup needs Node.js and Rokit.

## Rigs

- **R15 only.** A rig needs a Humanoid of rig type R15, must be under Workspace, must have the 15 standard R15 joints, and no two parts may share a name. R6 rigs and custom rigs are refused with `UNSUPPORTED_RIG`.
- **The 15 standard joints only.** Extra joints a rig has, such as for accessories, tools or a tail, can't be animated and aren't drawn in pose pictures.
- **`Motor6D` and `AnimationConstraint` joints.** Both have been measured to behave the same. Joints driven through forces (`AnimationConstraint` with `IsKinematic` off) are reported with a warning, since what Studio shows can then differ from the clip; how far it differs hasn't been measured.

## Clips

- **Keyframe clips and curve clips** (`KeyframeSequence` and `CurveAnimation`). A keyframe clip can be converted to curves, but a curve clip can't be turned back into keyframes.
- **Curve clips play at 30 frames a second.** Studio goes straight from frame to frame, so a key between frames is never shown at its own value. Keywright warns about such keys.
- **Content Keywright doesn't understand is kept, not edited.** Anything else a clip holds is left as it is, and `validate_animation` counts it as `OTHER_CONTENT`.
- **Limits per clip and per call:** clips up to 300 seconds long, up to 2,000 keyframes, or up to 2,000 keys per curve; up to 256 operations in one batch; up to 32 joints in one read or preview; up to 64 KiB of text in one read, with the rest in further reads.
- **Saved clips stay in the place.** Saving puts the clip where the Animation Editor keeps that rig's clips, inside the place. Keywright doesn't upload animations to Roblox; publish them from the Animation Editor. Save the place itself to keep them.
- **No tool deletes a saved clip.** Delete it in Studio's Explorer, or with Ctrl+Z straight after saving.

## Seeing the animation

- **No Studio screenshots.** The agent sees pose pictures: the rig drawn as boxes from the joint positions, not its real look. The screenshot code exists but is switched off until its behaviour has been checked independently.
- **No playback in Studio.** Keywright can't play a clip in the viewport for you. Open the saved clip in the Animation Editor to watch it.
- **The Keywright panel is small.** It has the access switch, pairing, and the approval of a replaced clip. It doesn't yet list connected AI apps, show validation results, or scrub through a clip.

## The checks

- **Measurements, not taste.** `validate_animation` finds structural errors, and measures things like speed, loops and contact with the floor. It can't say whether a motion looks good.
- **The default speed limits are rough.** 2,000° a second and 40 studs a second weren't tuned against real animations. A fast strike can go over them and still be right.
- **The floor is flat.** It is taken to be the rig's lowest point at rest. Parts are measured as boxes with rounded corners, so a part whose mesh is more rounded than that can be reported a little lower than it looks. The lower legs are left out of the floor check.
- **Feet:** when a foot comes down, it takes on the floor's speed in one frame, not gradually. A foot skimming the floor just before it lands can count as touching it.

## Working copies and Studio

- **One request at a time per Studio window.** A Studio window answers requests in order. The plugin stops waiting for a request after 90 seconds and moves on to the next one.
- **Studio can refuse undo steps.** Keywright makes no change it couldn't undo, so when Studio won't start an undo step, the change is refused. This was seen once, with the Animation Editor open, but not again when retried on 2026-11-26 with the editor open, with a clip loaded and with it playing, so the cause isn't known.
- **Playtests don't see edits.** During Play or Run, Studio runs a copy of the place. The agent's edits go to the place being edited, not to the running copy, and show once the playtest stops.
- **Revisions jump after an undo.** Undoing an edit gives the working copy a new revision, and the number can jump by more than one. Read the clip again before the next edit.
- **A working copy outlives its rig.** If the rig is deleted, its working copies stay listed until the plugin reloads.
- **Access is remembered per place.** A place that has never been saved to Roblox can't be told apart from other such places, so access there is off every time it opens.
