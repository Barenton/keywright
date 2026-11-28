# Errors and findings

Keywright reports two kinds of problem:

- **Errors** are what a tool returns when it could not do what was asked. Nothing is changed when a tool fails: a batch of edits either applies whole or not at all.
- **Findings** are what `validate_animation` (or `edit_animation` with `validate: true`) reports about a clip. A finding is an *error* finding when the clip is not structurally sound and cannot be saved, or a *warning* when it is a measurement worth looking at. Warnings never stop a save.

## Errors

A failed tool call returns `{"error": {"code": ..., "message": ..., "hint": ...}}`. The message says what went wrong in that case; the hint, when there is one, says what to do next.

| Code | What it means | What to do |
|---|---|---|
| `INVALID_ARGUMENT` | An argument is missing, of the wrong kind, or does not fit the clip: a joint the rig lacks, a time past the clip's end, an operation for the other kind of clip. In a batch, the message names the operation by its place in the list. | Correct the argument. Nothing was changed. |
| `NOT_FOUND` | The rig, working copy, saved clip or selection named does not exist. | Call `get_workspace` to see what there is. |
| `REVISION_CONFLICT` | `expected_revision` is not the working copy's current revision: it was changed since it was last read, by another call or by an undo in Studio. | Read the clip again and apply the change to the current revision. |
| `SOURCE_CHANGED` | A replacement was proposed for the clip a working copy was opened from, but that clip has been changed or removed since. | Open it again, or save the working copy as a new clip. |
| `VALIDATION_FAILED` | A save was refused because the clip has error findings. | Call `validate_animation`, correct what it reports, and save again. |
| `UNSUPPORTED_RIG` | The model is not a rig Keywright can work with: no Humanoid, not R15, not under Workspace, two parts with one name, or a standard joint missing. The message lists the reasons. | Use a standard R15 character under Workspace. See [Limitations](limitations.md). |
| `UNSUPPORTED_CLIP_FORMAT` | A curve clip was asked to become a keyframe clip, or a working copy converted to curves was proposed to replace the keyframe clip it came from. | Open curve clips as curves; save a converted copy as a new clip. |
| `LIMIT_EXCEEDED` | More than one call may ask for: over 256 operations in a batch, over 32 joints in one read or preview, more keyframes or keys than a clip may hold (2,000), and similar. The message gives the limit. | Split the work into smaller calls. |
| `STUDIO_NOT_IN_EDIT_MODE` | Studio refused to start an undo step, and Keywright makes no change it could not undo. Either an earlier Keywright change has not finished, or Studio is busy with something of its own; the Animation Editor playing a clip is one such thing. | Close the Animation Editor if it is open, or finish whatever is in progress in Studio, such as a dialog or a drag, and try again. If an earlier change never finishes, reload the plugin. |
| `PREVIEW_UNAVAILABLE` | The clip could not be played on the hidden copy of the rig: it did not load in time, it changed while it was being sampled, or the rig's Animator is already playing something. The rig itself was not changed. An edit that needs the clip's pose at a time can fail this way too. | Try again. Stop any animation playing on the rig. |
| `CAPTURE_UNAVAILABLE` | A Studio screenshot was asked for. Screenshots are switched off. | Use `render: true` for a pose picture instead. |
| `SESSION_NOT_FOUND` | No Studio window with that session id is connected. | Call `get_workspace`. In Studio, check that agent access is on in the Keywright panel. |
| `TIMEOUT` | Studio did not answer in time. The plugin stops waiting for a request after 90 seconds, and the adapter waits 30 seconds for most tools and 60 for previews. | Try again. If it keeps happening, reload the plugin. A change that timed out may still have been made, so read the clip before retrying an edit. |
| `CANCELLED` | The AI app cancelled the call. | Nothing to do. |
| `BROKER_UNAVAILABLE` | The adapter could not reach the broker, or lost its connection to it. | Try again: the adapter starts the broker when it is not running. `node keywright.mjs status` shows its state. |
| `BROKER_PORT_CONFLICT` | Another program is using the broker's port, 47318. | Close that program, then turn agent access off and on in the panel. |
| `INSTALL_FAILED` | `install-plugin` could not find Studio's plugins folder, or there is no built plugin to install. | Put `Keywright.rbxm` from the same release beside `keywright.mjs` (in a source checkout, build it with `npm run build:plugin`), or pass the folder: `node keywright.mjs install-plugin --folder <path>`. |
| `INTERNAL` | Something went wrong that Keywright did not expect. | Try again, and report it if it keeps happening. |

## Findings

Each finding has a `code`, a `severity`, a message, the joints and times it is about, and where it is a measurement, the `measured` value, its `unit` and the `limit` it was held to. At most 50 are listed, with `counts` of all of them. Limits can be changed for one call through `thresholds`; see [`validate_animation`](tools.md#validate_animation).

### Errors: the clip cannot be saved

| Code | What it means |
|---|---|
| `UNKNOWN_JOINT` | A pose or key is for a joint the rig does not have. |
| `DUPLICATE_KEYFRAME` | Two keyframes are at the same time, so which one plays is not defined. Keyframe clips only. |
| `DUPLICATE_POSE` | One joint has two poses in the same keyframe. Keyframe clips only. |
| `INVALID_KEYFRAME_TIME` | A keyframe or key is outside 0 to 300 seconds. |
| `NON_FINITE_TRANSFORM` | A pose or key holds a number that is not finite. |
| `POSITION_OUT_OF_RANGE` | A joint is moved more than 1,000 studs from its rest position. |
| `TOO_MANY_KEYFRAMES` | The clip has more than 2,000 keyframes. |
| `TOO_MANY_KEYS` | One curve has more than 2,000 keys. |

### Warnings: measurements to look at

| Code | What it means | Default limit |
|---|---|---|
| `LOOP_ROTATION_MISMATCH` | In a looping clip, a joint ends turned away from where it starts, so the loop jumps. | 2° (`loop_rotation_degrees`) |
| `LOOP_POSITION_MISMATCH` | The same for a joint's position. | 0.02 studs (`loop_position_studs`) |
| `ABRUPT_ROTATION` | A joint turns faster than the limit: between two keyframes, or in a curve clip at its fastest. Fast strikes and snaps can be meant. | 2,500° a second (`speed_degrees_per_second`). Good fast motion measured up to about 2,050°; a joint flipping between two frames turns at 5,400° or more. |
| `ABRUPT_MOVE` | A joint moves faster than the limit: between two keyframes, or in a curve clip at its fastest. | 40 studs a second (`speed_studs_per_second`). Good motion measured up to 13.4 (a backflip's hips); a jump of 2 studs in one frame moves at 60. |
| `BELOW_FLOOR` | Curve clips. A part goes below the floor, the floor being the rig's lowest point at rest. Parts are measured as boxes of their size with rounded corners, and the lower legs are left out. | 0.1 studs (`floor_studs`) |
| `FOOT_SCUFF` | Curve clips. A foot touches the floor while moving fast across it: a swinging foot that drags, or a planted one that skates. | Over 3 studs a second |
| `FOOT_SLIDE` | Curve clips. A foot on the floor creeps across it for three frames or more. | 0.1 studs (`slide_studs`) |
| `KEY_OFF_FRAME` | Curve clips. Keys are between frames. Studio plays curve clips at 30 frames a second and goes straight from frame to frame, so a key between frames is never shown at its own value. | Whole frames, multiples of 1/30 s |
| `NON_KINEMATIC_JOINT` | A joint is driven through forces (`IsKinematic` off), so what Studio shows can differ from the clip: measured on such a rig, a hand was 2.3 studs from where the clip put it. Previews and pictures show the clip as written. `inspect_rig` lists these joints and says so too. | |
| `POSE_HIERARCHY` | In a keyframe clip, a pose sits under a different parent pose than its part has in the rig. | |
| `OTHER_CONTENT` | The clip holds instances Keywright keeps as they are but does not edit or check. | |

These are measurements, not a judgement of how the motion looks. A speed warning on a punch's snap may be exactly what was wanted; a foot slide in a walk usually is not.
