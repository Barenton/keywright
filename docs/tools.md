# Tool reference

<!-- Written by `npm run docs:tools` from the tools the adapter offers. Do not edit by hand. -->

These are the tools Keywright gives an AI app, with the descriptions and arguments the app is given, word for word. Every tool except `get_workspace` and `pair_studio` takes `studio_session`, the id of a Studio window from `get_workspace`. A tool that fails returns an error with a `code`, a `message` and often a `hint`; the codes are listed in [Errors and findings](errors.md).

- [`get_workspace`](#get_workspace)
- [`get_guide`](#get_guide)
- [`install_plugin`](#install_plugin)
- [`pair_studio`](#pair_studio)
- [`inspect_rig`](#inspect_rig)
- [`open_animation`](#open_animation)
- [`read_animation`](#read_animation)
- [`edit_animation`](#edit_animation)
- [`validate_animation`](#validate_animation)
- [`save_animation`](#save_animation)
- [`discard_animation`](#discard_animation)
- [`preview_animation`](#preview_animation)

## How agents are asked to work

Besides the tools, an AI app is sent these instructions when it connects:

> Keywright makes animations for rigs in Roblox Studio. How to work with it:
>
> 1. Before animating, read the guide: get_guide (topic workflow) for how to plan, block, review and finish a clip, then the topic for what you are making (moves for walks, runs, strikes and the rest; rig for which way joints turn; review for reading the pictures and fixing what they show).
> 2. Start with get_workspace. If it, or any result, carries update_needed, tell the person straight away, with what it says to do: until the plugin and the adapter match, tools may fail or ignore options. When the plugin is the older one, install_plugin can update it if the person agrees. If get_workspace carries update_available, a newer release is out: mention it once, with its steps; it is not urgent. Use pair_studio only with a code the person gives you. Call inspect_rig before posing: its turns say which way each joint moves for a positive rotation about X, Y and Z.
> 3. Plan before editing. Write down the key poses, when each happens, and what each must read as: for a kick, the chamber, the contact (leg extended, hips turned over) and the recovery. Use curve clips (format "curves") for motion that should flow, with keys on whole frames (multiples of 1/30 s).
> 4. Block the key poses first and check them. Then add the in-betweens, overlap, and contacts with the floor (pin, place_on_floor).
> 5. After every revision, look at it. preview_animation with times at the key moments and render: true gives a pose strip, which shows whether each silhouette reads. With samples and render: true it gives motion paths and a speed plot, which show stops, pops and corners. Use both: a speed plot cannot tell you whether a pose reads, and a pose strip cannot show timing. Use compare_with to see what a revision changed, onion: true to see how a limb travels between poses, and measure to turn a check (a punch's reach, how low the hips sink after a landing) into numbers.
> 6. validate_animation finds structural errors and measures loops, speeds and feet. Passing it is necessary, not enough. The animation is done when every key moment reads in the pose strip, the motion has no stops you did not plan, feet that should stay planted do, and a loop closes.
> 7. Save with save_animation under a new name. Replace a clip the person already has only when they ask, and then they approve it in Studio. Tell the person what you made and ask them to play it in the Animation Editor: the pictures are schematics, not the rig's real look.

## get_workspace

*Reads only: changes nothing in Studio.*

List connected Roblox Studio sessions with their rigs, working copies and revisions, the current selection, and whether screenshots are available. A session whose plugin is a different version from this adapter carries update_needed, saying what to ask the person to update; every other tool's result for that session carries it too. Tell the person when you see it.

No arguments.

## get_guide

*Reads only: changes nothing in Studio.*

Read Keywright's animator's guide: how to plan key poses, block them, review every revision in pictures and numbers, and know when a clip is done; which way R15 joints turn; timing and method for walks, runs, strikes, jumps and the rest; and what to change for each kind of problem. Read the workflow before animating, and the topic for what you are making. The same text as the Keywright skill, and always for this version of the tools.

| Argument | Type | Required | Description |
|---|---|---|---|
| `topic` | one of `workflow`, `rig`, `moves`, `review` |  | "workflow" (default): the whole process, start to finish. "rig": which way joints turn, posing, traps. "moves": timing and method for each kind of move. "review": reading pose strips, motion plots, onion skins and measurements, and fixing what they show. |
| `section` | text, 1 to 80 characters |  | Only one section of the topic, by its heading or the start of it, ignoring case: "Run cycle", "strikes", "Interruptions". Default: the whole topic. Every answer ends with the topic's sections, so the part needed next can be asked for alone. |

## install_plugin

Install or update the Keywright plugin in Roblox Studio's plugins folder for this user, from this copy of Keywright, so the plugin and this adapter match. Only when the person asks, or agrees after update_needed says the plugin is older; it works from apps whose own commands can't reach Studio's folder, since Keywright itself runs on the person's computer. It writes Keywright's plugin file there, replacing an older one and a copy saved from Studio by hand; other plugins are left. It refuses to put back an older plugin than one a connected Studio window runs. Studio loads the new plugin on its own; if the panel still shows an older version at its bottom, the person reopens the place or restarts Studio.

No arguments.

## pair_studio

Pair a Studio window with Keywright, once per Studio install. When a person turns on agent access in a Studio that has never been paired, the Keywright panel shows a one-time code, and the person may give it to you. Register only a code the person gave you; never guess one. Codes last 5 minutes and work once. Afterwards the panel says it is connected, and the window appears in get_workspace within a few seconds. Studio remembers the pairing, so this is not needed again.

| Argument | Type | Required | Description |
|---|---|---|---|
| `code` | text, 1 to 64 characters | yes | The code the Keywright panel shows, as the person gave it. Spaces, dashes and case do not matter. |

## inspect_rig

*Reads only: changes nothing in Studio.*

Describe a rig: joint names, hierarchy, joint class (Motor6D or AnimationConstraint) and rest transforms. Returns a summary unless detail is true.

| Argument | Type | Required | Description |
|---|---|---|---|
| `studio_session` | text | yes | Which Studio window to act in: a session id from get_workspace. |
| `rig_id` | text | yes | Which rig: a rig_id from get_workspace. |
| `detail` | true or false |  | Include per-joint rest transforms and part sizes. |

## open_animation

Create a working copy to edit: blank, or copied from an existing clip. The source clip is never changed. A clip is either keyframes (KeyframeSequence: poses at keyframes, each stretch between two eased by one of a few fixed shapes) or curves (CurveAnimation: each joint channel its own curve through a few keys, with tangents, as in the Curve Editor). Curves are the better choice for motion that should flow: speed carries through a key instead of stopping or turning a corner at it, and a person can keep editing the result in the Animation Editor's Curve Editor. Studio plays a curve clip at 30 frames a second, going straight from frame to frame, so put keys on whole frames: multiples of 1/30 s (0.0333, 0.0667, 0.1, ...). Opening a keyframe clip with format "curves" converts it: the keys pass through every pose, with smooth tangents, so the motion between poses can differ.

| Argument | Type | Required | Description |
|---|---|---|---|
| `studio_session` | text | yes | Which Studio window to act in: a session id from get_workspace. |
| `rig_id` | text | yes | Which rig: a rig_id from get_workspace. |
| `name` | text, 1 to 100 characters |  | Name of the working copy, and the name it is saved under unless save_animation is given another. Default: the source's name, or "Untitled" for a blank clip. |
| `source` | text, up to 110 characters |  | Omit for a blank clip. "selection" copies the clip selected in the Explorer. "saved:" followed by a name copies that saved clip of the rig, as listed by get_workspace. |
| `format` | one of `keyframes`, `curves` |  | What the working copy is made of. Default: the source's format, or keyframes for a blank clip. A curve clip cannot be turned into keyframes. |

## read_animation

*Reads only: changes nothing in Studio.*

Read a working copy. Returns a summary: format, duration, keyframe times, animated joints, markers, settings, revision, and a count of any content Keywright keeps but does not edit. For the joints listed, a keyframe clip returns poses and a curve clip returns keys: one per channel (rotation.x/y/z in degrees, position.x/y/z in studs) with interpolation and tangents in and out (per second). Only as many as fit are returned; when there are more, next_cursor says so, and passing it back as cursor returns the next part.

| Argument | Type | Required | Description |
|---|---|---|---|
| `studio_session` | text | yes | Which Studio window to act in: a session id from get_workspace. |
| `clip_id` | text | yes | Working copy id from open_animation or get_workspace. |
| `joints` | list of texts (up to 32 items) |  | Joints whose poses to return. Default: none, only the summary. |
| `time_from` | number, at least 0 |  | Only keyframes from this time, in seconds. |
| `time_to` | number, at least 0 |  | Only keyframes up to this time, in seconds. |
| `rotation_format` | one of `euler`, `quaternion` |  | How pose rotations are returned. Default: Euler angles in degrees, X, Y, Z order. |
| `cursor` | text, up to 64 characters |  | next_cursor from an earlier read of the same clip with the same joints and times. Returns the poses after it, without the summary. |
| `max_bytes` | whole number, 1024 to 65536 |  | Most text to return, in bytes. Default 16384. |
| `hash` | true or false |  | Include content_hash, a fingerprint of everything that affects how the clip plays. Two clips with the same fingerprint are the same apart from their names. |

## edit_animation

Apply a batch of operations to a working copy atomically. A keyframe clip takes poses, easing, keyframes and smoothing; a curve clip takes keys, tangents, auto_tangents, add_offset, add_noise, aim, clear_floor, clear_keys, copy_pose, mirror, nudge, overlap, pin, place_on_floor, reduce_keys and reverse_time. Both take shift_time and scale_time (retiming), markers, the clip's settings and restore_source; each operation's description says which clips it is for. The operations apply in the order given, each to the clip as the ones before it leave it. The whole batch is tried first; if any operation cannot be done, nothing changes and the error names it by its place in the list. Requires the current revision. One Studio undo reverts the whole batch. Only what an operation names is changed.

| Argument | Type | Required | Description |
|---|---|---|---|
| `studio_session` | text | yes | Which Studio window to act in: a session id from get_workspace. |
| `clip_id` | text | yes | Working copy id from open_animation or get_workspace. |
| `expected_revision` | text | yes | Revision from the last read or edit of this clip. |
| `operations` | list of objects (1 to 256 items) | yes | The operations, applied in order. Each is one kind of edit, named by its type. |
| `validate` | true or false |  | Also run validate_animation's checks, with its default limits, on the clip as the edit leaves it. The result then has validation: valid, the counts of each finding, and the first 10 findings. Saves a call after each edit. |

### Operations

Each item of `operations` is one of these, chosen by its `type`.

[`set_pose`](#set_pose) · [`remove_pose`](#remove_pose) · [`offset_pose`](#offset_pose) · [`set_easing`](#set_easing) · [`add_keyframe`](#add_keyframe) · [`remove_keyframe`](#remove_keyframe) · [`move_keyframe`](#move_keyframe) · [`duplicate_keyframe`](#duplicate_keyframe) · [`smooth_motion`](#smooth_motion) · [`shift_time`](#shift_time) · [`scale_time`](#scale_time) · [`set_properties`](#set_properties) · [`set_marker`](#set_marker) · [`remove_marker`](#remove_marker) · [`restore_source`](#restore_source) · [`set_key`](#set_key) · [`remove_key`](#remove_key) · [`set_tangent`](#set_tangent) · [`auto_tangents`](#auto_tangents) · [`clear_keys`](#clear_keys) · [`copy_pose`](#copy_pose) · [`add_offset`](#add_offset) · [`add_noise`](#add_noise) · [`reduce_keys`](#reduce_keys) · [`reverse_time`](#reverse_time) · [`mirror`](#mirror) · [`pin`](#pin) · [`nudge`](#nudge) · [`aim`](#aim) · [`overlap`](#overlap) · [`place_on_floor`](#place_on_floor) · [`clear_floor`](#clear_floor)

#### set_pose

Set a joint's pose at a time. The keyframe is created if there is none within a millisecond.

| Field | Type | Required | Description |
|---|---|---|---|
| `joint` | text | yes | Name of the driven part, for example RightUpperArm. |
| `time` | number, 0 to 300 | yes | Keyframe time in seconds. |
| `position` | 3 numbers |  | Joint-local offset from the rest pose, in studs. |
| `rotation` | 3 numbers |  | Joint-local rotation as Euler angles in degrees, applied in X, Y, Z order. |
| `quaternion` | 4 numbers |  | Joint-local rotation as a quaternion (x, y, z, w) of length 1, in place of rotation. |
| `relative` | true or false |  | Apply on top of the existing pose instead of replacing it. |
| `easing_style` | one of `Linear`, `Constant`, `Elastic`, `CubicV2`, `Bounce` |  | How the joint moves from this pose to its next one. A pose's easing shapes the stretch that starts at it, not the one that ends at it. The deprecated Cubic style is kept where a clip has it but cannot be set. |
| `easing_direction` | one of `In`, `Out`, `InOut` |  | In starts slowly and ends fast; Out starts fast and ends slowly; InOut is slow at both ends. For a jump, the rise is Out and the fall is In. |

#### remove_pose

Remove a joint's pose from a keyframe, so that the joint is no longer keyed there.

| Field | Type | Required | Description |
|---|---|---|---|
| `joint` | text | yes | Name of the driven part, for example RightUpperArm. |
| `time` | number, 0 to 300 | yes | Time of the keyframe in seconds. |

#### offset_pose

Apply an offset on top of every existing pose of a joint in a time range.

| Field | Type | Required | Description |
|---|---|---|---|
| `joint` | text | yes | Name of the driven part, for example RightUpperArm. |
| `time_from` | number, 0 to 300 | yes | Start of the time range in seconds. Keyframes at the ends are included. |
| `time_to` | number, 0 to 300 | yes | End of the time range in seconds. |
| `position` | 3 numbers |  | Joint-local offset from the rest pose, in studs. |
| `rotation` | 3 numbers |  | Joint-local rotation as Euler angles in degrees, applied in X, Y, Z order. |
| `quaternion` | 4 numbers |  | Joint-local rotation as a quaternion (x, y, z, w) of length 1, in place of rotation. |

#### set_easing

Set the easing of every existing pose of a joint in a time range.

| Field | Type | Required | Description |
|---|---|---|---|
| `joint` | text | yes | Name of the driven part, for example RightUpperArm. |
| `time_from` | number, 0 to 300 | yes | Start of the time range in seconds. Keyframes at the ends are included. |
| `time_to` | number, 0 to 300 | yes | End of the time range in seconds. |
| `easing_style` | one of `Linear`, `Constant`, `Elastic`, `CubicV2`, `Bounce` |  | How the joint moves from this pose to its next one. A pose's easing shapes the stretch that starts at it, not the one that ends at it. The deprecated Cubic style is kept where a clip has it but cannot be set. |
| `easing_direction` | one of `In`, `Out`, `InOut` |  | In starts slowly and ends fast; Out starts fast and ends slowly; InOut is slow at both ends. For a jump, the rise is Out and the fall is In. |

#### add_keyframe

Add an empty keyframe. Refused if there is one within a millisecond.

| Field | Type | Required | Description |
|---|---|---|---|
| `time` | number, 0 to 300 | yes | Time of the new keyframe in seconds. |
| `hold` | true or false |  | Key every joint the clip moves at the pose it already has at this time, as Studio plays it, so that the clip passes through the same pose there. Between keyframes the motion stays the same only for joints whose easing is Linear or Constant; for any other easing the result lists the joint under held[].motion_changed, because splitting an eased stretch in two changes its shape. At most 8 per batch. |

#### remove_keyframe

Remove a keyframe with everything in it.

| Field | Type | Required | Description |
|---|---|---|---|
| `time` | number, 0 to 300 | yes | Time of the keyframe in seconds. |

#### move_keyframe

Move one keyframe to another time. Refused if a keyframe is already there.

| Field | Type | Required | Description |
|---|---|---|---|
| `time` | number, 0 to 300 | yes | Time of the keyframe in seconds. |
| `to` | number, 0 to 300 | yes | Its new time in seconds. |

#### duplicate_keyframe

Copy a keyframe, with its poses and markers, to another time. Refused if a keyframe is already there.

| Field | Type | Required | Description |
|---|---|---|---|
| `time` | number, 0 to 300 | yes | Time of the keyframe to copy, in seconds. |
| `to` | number, 0 to 300 | yes | Time of the copy in seconds. |

#### smooth_motion

Run one smooth curve through each joint's keys in a time range and write it out as a pose at every step, replacing those keys. Roblox eases each stretch between two keys by itself, so a move made of several eased stretches stops at every key and one made of straight stretches turns a corner at every key. The curve instead carries speed through a key the motion passes on its way, comes to rest only where the motion turns round, and never goes past a key. Block out the move with a few keys per joint, then smooth it. Keyframes that hold markers are kept. Joints with fewer than two keys in the range are left as they are.

| Field | Type | Required | Description |
|---|---|---|---|
| `time_from` | number, 0 to 300 | yes | Start of the time range in seconds. Keyframes at the ends are included. |
| `time_to` | number, 0 to 300 | yes | End of the time range in seconds. |
| `joints` | list of texts (1 to 32 items) |  | The joints to smooth. Default: every joint the clip moves. |
| `rate` | whole number, 10 to 60 |  | Poses written per second. Default 30. |
| `snap_at` | list of numbers, 0 to 300 (up to 16 items) |  | Key times that are struck, not eased into: the motion arrives there fast and stops dead, as a fist on what it hits. |
| `loop` | true or false |  | Carry speed across from the last key to the first. Default: true when the clip loops and the range is the whole clip. |

#### shift_time

Move every keyframe in a time range by the same amount; in a curve clip, every key of every joint and every marker, each onto the nearest whole frame. Refused if one would land on or pass a key or keyframe outside the range.

| Field | Type | Required | Description |
|---|---|---|---|
| `time_from` | number, 0 to 300 | yes | Start of the time range in seconds. Keyframes at the ends are included. |
| `time_to` | number, 0 to 300 | yes | End of the time range in seconds. |
| `offset` | number | yes | Seconds to move by; negative moves earlier. |
| `wrap` | true or false |  | Curve clips that loop, over the whole clip only: start the loop somewhere else. Everything moves on by the offset and what goes past the end comes round to the start, the curves cut exactly where the loop now begins; the loop should close (end in the pose it begins with, as copy_pose makes it). For room before a moment at the start, as a step eased into a heel strike at 0. Use whole frames. |

#### scale_time

Stretch or squeeze the keyframes in a time range, to make that part of the move slower or faster. In a curve clip, every key of every joint and every marker in the range, each onto the nearest whole frame, with tangents scaled so the curves keep their shape; keys squeezed onto one frame are joined into one, and the result counts keys_merged with first_merge_at. Refused if one would land on or pass a key or keyframe outside the range, unless ripple carries those along.

| Field | Type | Required | Description |
|---|---|---|---|
| `time_from` | number, 0 to 300 | yes | Start of the time range in seconds. Keyframes at the ends are included. |
| `time_to` | number, 0 to 300 | yes | End of the time range in seconds. |
| `factor` | number, 0.01 to 100 | yes | 2 makes the range twice as long, 0.5 half as long. |
| `anchor` | number, 0 to 300 |  | The time that stays where it is. Default: time_from. |
| `ripple` | true or false |  | Also move everything after the range by as much as its end moves, so the rest of the clip keeps its own timing and the clip grows or shrinks. Default false. |

#### set_properties

Change the clip's own settings. Give at least one.

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | text, 1 to 100 characters |  | The clip's new name. |
| `loop` | true or false |  | Whether the clip plays over and over. |
| `priority` | one of `Idle`, `Movement`, `Action`, `Action2`, `Action3`, `Action4`, `Core` |  | The priority Roblox plays the clip at. Where two playing clips move the same joint, the one of higher priority moves it. |

#### set_marker

Add a marker to the keyframe at a time, or change its value. The keyframe is created if absent.

| Field | Type | Required | Description |
|---|---|---|---|
| `time` | number, 0 to 300 | yes | Time of the keyframe in seconds. |
| `name` | text, 1 to 100 characters | yes | The marker's name. |
| `value` | text, up to 200 characters |  | Default: empty. |

#### remove_marker

Remove a marker from the keyframe at a time.

| Field | Type | Required | Description |
|---|---|---|---|
| `time` | number, 0 to 300 | yes | Time of the keyframe in seconds. |
| `name` | text, 1 to 100 characters | yes | The marker's name. |

#### restore_source

Reset the working copy to the clip it was opened from.

No fields.

#### set_key

Curve clips only. Put a key at a time on a joint's rotation curves, position curves, or both; a key already within a millisecond is changed. A new key starts with flat tangents; run auto_tangents afterwards for smooth motion, or set them with set_tangent.

| Field | Type | Required | Description |
|---|---|---|---|
| `joint` | text | yes | Name of the driven part, for example RightUpperArm. |
| `time` | number, 0 to 300 | yes | Key time in seconds. |
| `rotation` | 3 numbers |  | Joint-local rotation as Euler angles in degrees, X, Y, Z order, each its own curve. |
| `position` | 3 numbers |  | Joint-local offset from rest, in studs. |
| `interpolation` | one of `Cubic`, `Linear`, `Constant` |  | How the stretch from this key to the next is played: Cubic follows the tangents, Linear is straight, Constant holds. Default Cubic for a new key. |

#### remove_key

Curve clips only. Remove a joint's keys at a time.

| Field | Type | Required | Description |
|---|---|---|---|
| `joint` | text | yes | Name of the driven part, for example RightUpperArm. |
| `time` | number, 0 to 300 | yes | Key time in seconds. |
| `channels` | list of any of `rotation`, `position` (1 to 2 items) |  | Default: both. |

#### set_tangent

Curve clips only. Set the slope of one channel's curve as it arrives at (in) and leaves (out) a key: how fast the value is changing there. 0 is at rest. Leaving with out makes the stretch after the key cubic.

| Field | Type | Required | Description |
|---|---|---|---|
| `joint` | text | yes | Name of the driven part, for example RightUpperArm. |
| `time` | number, 0 to 300 | yes | Key time in seconds. |
| `channel` | one of `rotation.x`, `rotation.y`, `rotation.z`, `position.x`, `position.y`, `position.z` | yes | Which of the joint's curves: its rotation about x, y or z, or its position along x, y or z. |
| `in` | number |  | Degrees per second for rotation, studs per second for position. |
| `out` | number |  | Degrees per second for rotation, studs per second for position. |

#### auto_tangents

Curve clips only. Give every key in a time range the tangents of one smooth curve through its channel's keys: a key the motion passes on its way is passed at speed, a key where it turns round is come to rest at, and nothing goes past a key. Keys in the range become Cubic. The usual last step after placing keys.

| Field | Type | Required | Description |
|---|---|---|---|
| `time_from` | number, 0 to 300 | yes | Start of the time range in seconds. Keyframes at the ends are included. |
| `time_to` | number, 0 to 300 | yes | End of the time range in seconds. |
| `joints` | list of texts (1 to 32 items) |  | Default: every joint. |
| `snap_at` | list of numbers, 0 to 300 (up to 16 items) |  | Key times that are struck, not eased into: the motion arrives fast and stops dead, as a fist on what it hits. |
| `loop` | true or false |  | Carry speed across from the last key to the first. Default: true when the clip loops and the range is the whole clip. |

#### clear_keys

Curve clips only. Remove every key in a time range, ends included, from the joints and channels named; the curves then run straight from the last key before the range to the first after it. A curve holds its first key's value back to the start, so clearing from 0 changes the start too. To redo a pin or place_on_floor over another range, clear the keys they wrote first: the old range with its blends, on the limb's three joints (rotation) or the hips (position). Never an error when the range holds no key; the result counts keys_removed.

| Field | Type | Required | Description |
|---|---|---|---|
| `time_from` | number, 0 to 300 | yes | Start of the time range in seconds. Keyframes at the ends are included. |
| `time_to` | number, 0 to 300 | yes | End of the time range in seconds. |
| `joints` | list of texts (1 to 32 items) |  | Default: every joint. |
| `channels` | list of any of `rotation`, `position` (1 to 2 items) |  | Default: both. |

#### copy_pose

Curve clips only. Copy the pose the clip has at one time to a key at another, for every joint or those named: end a loop in exactly the pose it starts with, come back to a guard pose, hold a pose. With from_clip, the pose comes from another clip of the same rig: carry a revised guard from a ready clip into each attack's start and recovery, copying only the joints and channels named, so the attack's feet, timing and markers stay as they are. With mirror, the pose is copied as its mirror image, left onto right: a walk's left contact pose becomes the right one. A key already at `to` gets the new value and keeps its tangents; a new one starts flat, as with set_key, so run auto_tangents afterwards for smooth motion. The result counts keys_created and keys_changed.

| Field | Type | Required | Description |
|---|---|---|---|
| `from` | number, 0 to 300 | yes | The time whose pose is copied, in seconds: in from_clip when it is given. |
| `to` | number, 0 to 300 | yes | The time to put it at, in seconds. |
| `from_clip` | text, 1 to 120 characters |  | Another clip of the same rig to copy the pose from, named as compare_with names one: "source" (the clip this working copy was opened from), "saved:" and the name of one of the rig's saved clips, or another working copy's clip id. It is only read; a keyframe clip is read as it plays. Default: this clip. |
| `joints` | list of texts (1 to 32 items) |  | The joints to key at `to`. Default: every joint. With mirror, each takes the pose of its counterpart on the other side. |
| `mirror` | true or false |  | Copy the pose as its mirror image. Default false. |
| `channels` | list of any of `rotation`, `position` (1 to 2 items) |  | Default: both. |

#### add_offset

Curve clips only. Add a turn or a move to one joint over a time range, on top of the motion it has, easing in and out: lean the chest further forward through a punch, drop the hips lower while landing, without working out new angles at every key. The amounts are added to the joint's own angles, as set_key gives them, and its position. Written at every frame and then reduced to as few keys as keep it, so the curves stay editable. The joint's motion outside the range and its blends is unchanged.

| Field | Type | Required | Description |
|---|---|---|---|
| `joint` | text | yes | Name of the driven part, for example RightUpperArm. |
| `time_from` | number, 0 to 300 | yes | Start of the range in seconds. In a looping clip it may be after time_to: the range then runs on past the end and round from the start, as a step that lands just after the loop begins (time_from 0.9, time_to 0.2), blends included. |
| `time_to` | number, 0 to 300 | yes | End of the range in seconds. Must not be past the end of the clip. In a looping clip, a range or blend that reaches the end, or the start, changes both alike, so the loop stays closed. |
| `rotation` | 3 numbers |  | Degrees to add about X, Y and Z, as in set_key. |
| `position` | 3 numbers |  | Studs to add, as in set_key. |
| `blend_in` | number, 0 to 2 |  | Seconds before time_from over which it eases in. Default 0. |
| `blend_out` | number, 0 to 2 |  | Seconds after time_to over which it eases out. Default 0. |

#### add_noise

Curve clips only. Add a smooth, slow sway on top of the motion of the joints named: breathing and weight shifts in an idle, a tremble, the shake of a hit. Each joint and channel sways its own way, from three waves at chance phases, and the same seed always gives the same sway. Over the whole of a looping clip, the sway ends where it began. Written at every frame and then reduced to as few keys as keep it.

| Field | Type | Required | Description |
|---|---|---|---|
| `joints` | list of texts (1 to 32 items) | yes | The joints that sway. |
| `time_from` | number, 0 to 300 | yes | Start of the range in seconds. In a looping clip it may be after time_to: the range then runs on past the end and round from the start, as a step that lands just after the loop begins (time_from 0.9, time_to 0.2), blends included. |
| `time_to` | number, 0 to 300 | yes | End of the range in seconds. Must not be past the end of the clip. In a looping clip, a range or blend that reaches the end, or the start, changes both alike, so the loop stays closed. |
| `rotation_degrees` | number, 0 to 90 |  | About how far each rotation channel sways either way, in degrees. Default 0. |
| `position_studs` | number, 0 to 5 |  | About how far each position channel sways either way, in studs. Default 0. |
| `frequency` | number, 0.1 to 10 |  | Waves a second of the slowest sway; the others are about twice and four times as fast. Default 1. |
| `seed` | whole number |  | Another seed gives another sway. Default 1. |
| `blend_in` | number, 0 to 2 |  | Seconds before time_from over which it eases in. Default 0. |
| `blend_out` | number, 0 to 2 |  | Seconds after time_to over which it eases out. Default 0. |

#### reduce_keys

Curve clips only. Rebuild each channel in a range from as few keys as keep it within a tolerance of how it plays now, at every frame Studio shows. pin, place_on_floor and a squeeze leave a key on every frame; reducing them afterwards leaves curves a person can edit in the Curve Editor, and reads that are far shorter. The keys at the ends of the range stay as they are. At most 60 seconds at once. The result counts keys_removed.

| Field | Type | Required | Description |
|---|---|---|---|
| `time_from` | number, 0 to 300 | yes | Start of the time range in seconds. Keyframes at the ends are included. |
| `time_to` | number, 0 to 300 | yes | End of the time range in seconds. |
| `joints` | list of texts (1 to 32 items) |  | Default: every joint. |
| `rotation_degrees` | number, over 0, up to 10 |  | How far a rotation may stray, in degrees. Default 0.1. |
| `position_studs` | number, over 0, up to 10 |  | How far a position may stray, in studs. Default 0.002. |

#### reverse_time

Curve clips only. Play a time range backward: each key at time t moves to time_from + time_to - t, with its tangents turned round, and markers with them. A get-up reversed is a fall; a reach reversed is a return.

| Field | Type | Required | Description |
|---|---|---|---|
| `time_from` | number, 0 to 300 | yes | Start of the time range in seconds. Keyframes at the ends are included. |
| `time_to` | number, 0 to 300 | yes | End of the time range in seconds. |

#### mirror

Curve clips only. Mirror motion across the rig's middle, from its left side to its right. flip turns the whole clip into its mirror image: a punch with the right hand becomes the same punch with the left, the hips' and chest's turns and sideways moves reversed. left_to_right and right_to_left copy one side's motion onto the other side, mirrored, and leave the middle and the side copied from as they are. The keys themselves are mirrored, tangents included, so the result is exact and keeps the keys it had, editable in the Curve Editor. A joint copied from that does not move leaves its mirror not moving. Refused on a rig whose sides are not mirror images of each other.

| Field | Type | Required | Description |
|---|---|---|---|
| `mode` | one of `flip`, `left_to_right`, `right_to_left` | yes | flip, left_to_right or right_to_left, as described above. |
| `joints` | list of texts (1 to 32 items) |  | Only these joints and their counterparts on the other side, for example LeftUpperLeg, LeftLowerLeg and LeftFoot for one leg. Default: every joint. |
| `offset` | number |  | With left_to_right or right_to_left in a looping clip: seconds later that the copied side does what the other side did, carried round from the end to the start. Half the clip's length makes a walk or run cycle from one leg and one arm. |

#### pin

Curve clips only. Hold a foot or hand in place over a time range, or put it somewhere and hold it there, by turning the limb's three joints at every frame: a planted foot stays put while the hips move, a hand stays on a wall while the body leans. The knee or elbow bends the way it bends and keeps pointing as it was animated unless pole is given. The hips and everything else are left as they are. The limb's rotation keys in the range are replaced by one key a frame, with smooth tangents; outside the range the clip is unchanged. The result counts frames_pinned and, if the hips went too far for the limb to reach, frames_out_of_reach, largest_miss_studs, and out_of_reach_from and out_of_reach_to: the first and last of those frames, in seconds, where the hips are to be brought nearer (in a range across a loop's end, the first can be after the last). For a landing, hold the pose the foot settles in (at the end of the range), not the one it touches down in, or it is held where it first touched, often still in the air. End the range, and any blend_out, where the foot leaves the floor: easing out while it is still down lets it slide.

| Field | Type | Required | Description |
|---|---|---|---|
| `part` | one of `LeftFoot`, `RightFoot`, `LeftHand`, `RightHand` | yes | The end of the limb to hold. |
| `time_from` | number, 0 to 300 | yes | Start of the range in seconds. In a looping clip it may be after time_to: the range then runs on past the end and round from the start, as a step that lands just after the loop begins (time_from 0.9, time_to 0.2), blends included. |
| `time_to` | number, 0 to 300 | yes | End of the range in seconds. Must not be past the end of the clip. In a looping clip, a range or blend that reaches the end, or the start, changes both alike, so the loop stays closed. |
| `at` | number, 0 to 300 |  | The time whose pose is held: the part stays where it is then. Default time_from. |
| `position` | 3 numbers |  | Where the part's middle is to be instead, in studs from the root part: x toward the rig's right, y up, z toward its back. With relative_to, in studs from that part's middle along its own directions instead. |
| `pivot` | one of `ankle`, `toe`, `heel` |  | Feet only. The point of the foot that stays put. ankle (default) holds the foot as hold says. toe or heel holds that point, the middle of the sole's front or back edge, and the foot turns about it by roll, keeping its facing across the floor whatever the hips and leg above it do. With position or on_floor, those place the point; on_floor also sets the foot flat before it rolls. Not with hold position. |
| `roll` | 2 numbers |  | With a toe or heel pivot: how far, in degrees, the foot's other end is lifted off the floor at time_from and at time_to, easing between: toe with [0, 40] peels up onto the toe as a step pushes off; heel with [25, 0] lands heel first and rolls down onto the sole. At time_from the foot is taken to be lifted by the first angle already, so rolls one after another join up: up with [0, 30], back down with [30, 0]. Default [0, 0]. |
| `travel` | 3 numbers, or `match` |  | Studs a second the held point moves, in the same space as position, starting from where it is at `at`: a foot planted on a floor that moves, as in a walk or run cycle made on the spot, where the planted foot moves back steadily under the body. For a cycle facing forward, a positive z (toward the back). "match" takes the speed from the clip's own motion of the held point over the range, where it is at time_from and at time_to, before the pin (across the floor only with on_floor), and the result gives it as travel_x, travel_y and travel_z. The point moves on through blend_in and blend_out as well, so a foot eased in lands already moving with the floor, and one eased out leaves with it. A toe or heel pivot moves with it. |
| `fit_hips` | true or false |  | Where the held point is beyond the limb's reach (less soft), lower the hips straight down by just enough for it to be reached, at that frame only: a crouch to pick something up, a lunge, a long stride. The result counts frames_hips_lowered with largest_hip_drop_studs. Not with relative_to. |
| `keep` | list of any of `LeftFoot`, `RightFoot`, `LeftHand`, `RightHand` (up to 3 items) |  | With fit_hips: the other hands or feet to keep exactly where they were while the hips move, as the other foot planted on the floor. |
| `soft` | number, 0 to 0.5 |  | Soften the limb's reach over this last share of it, from 0 to 0.5: near full stretch the point is reached for ever more slowly and never quite reached, so the knee or elbow never locks straight or snaps through its last degrees, as hips rising off a planted foot. 0.02 to 0.05 suits a planted foot; 0.1 keeps the knee well bent. The result gives largest_soft_studs, how far short of the point that left the part; such frames are not out of reach. Default 0. |
| `on_floor` | true or false |  | Hold the part where it is across the floor, but set flat, turned only about the vertical, with its underside on the floor: plants a foot properly even where the clip has it sunk or lifted at `at`, as after lowering the hips on straight legs. Not with relative_to; position's height is replaced. |
| `relative_to` | one of `LowerTorso`, `UpperTorso`, `Head`, `LeftUpperArm`, `LeftLowerArm`, `LeftHand`, `RightUpperArm`, `RightLowerArm`, `RightHand`, `LeftUpperLeg`, `LeftLowerLeg`, `LeftFoot`, `RightUpperLeg`, `RightLowerLeg`, `RightFoot` |  | Hold the part against another part instead of in place, re-placed at every frame as that part moves: a hand on the chest stays on the chest while the body bends, a hand on a knee stays on it as the knee rises. Without position, the part keeps where it was against that part at `at`. Not a part of the limb itself. |
| `hold` | one of `full`, `position` |  | full (default) holds the part's position and rotation, as a foot flat on the ground. position holds only where the ankle or wrist is, and the foot or hand keeps its own animated turn. |
| `pole` | 3 numbers |  | A point the knee or elbow is to point toward, in the same space as position (so also against relative_to when given). |
| `blend_in` | number, 0 to 2 |  | Seconds before time_from over which the limb eases from its own motion into the hold. While easing in or out, the part travels straight from where its own motion has it to where it is held, turning evenly between the two. Default 0. |
| `blend_out` | number, 0 to 2 |  | Seconds after time_to over which it eases back out. Default 0. |

#### nudge

Curve clips only. Move a foot or hand off its own path by an offset for a few frames, easing in and out, by turning the limb's three joints at every frame: lift a kicking foot at the chamber, carry a punch a little higher, clear a scuffing toe. Unlike pin, which holds the part at one point, the part keeps travelling along its own motion, moved by its share of the offset at each frame, so a fast limb is not dragged back toward a held point. The hips and everything else are left as they are, and frames outside the range and its blends are unchanged. The limb's rotation keys in the range are replaced by one key a frame, with smooth tangents; run reduce_keys after. Use track or measure to read where the part is before choosing the offset, and an onion skin to compare its path before and after. The result counts frames_nudged and largest_nudge_studs, and frames_out_of_reach with largest_miss_studs where the limb could not reach.

| Field | Type | Required | Description |
|---|---|---|---|
| `part` | one of `LeftFoot`, `RightFoot`, `LeftHand`, `RightHand` | yes | The end of the limb to move. |
| `time_from` | number, 0 to 300 | yes | Start of the range in seconds. In a looping clip it may be after time_to: the range then runs on past the end and round from the start, as a step that lands just after the loop begins (time_from 0.9, time_to 0.2), blends included. |
| `time_to` | number, 0 to 300 | yes | End of the range in seconds. Must not be past the end of the clip. In a looping clip, a range or blend that reaches the end, or the start, changes both alike, so the loop stays closed. |
| `offset` | 3 numbers | yes | How far to move it, in studs, in the rig's own directions: x toward its right, y up, z toward its back (forward is negative z). All of it from time_from to time_to, a share of it while easing in and out. |
| `blend_in` | number, 0 to 2 |  | Seconds before time_from over which the offset eases in from nothing; the frame where it starts is unchanged. Default 0. |
| `blend_out` | number, 0 to 2 |  | Seconds after time_to over which it eases out; the frame where it ends is unchanged. Default 0. |
| `hold` | one of `full`, `position` |  | full (default) moves the part without turning it, as a point dragged along its trail. position moves only the ankle or wrist, and the foot or hand turns with the limb. |
| `soft` | number, 0 to 0.5 |  | Soften the limb's reach over this last share of it, as pin's soft does. Default 0. |

#### aim

Curve clips only. Turn one joint so the front of its part faces a point over a time range, by the smallest turn from how it is animated: a head that watches an opponent through a whole combo, a chest that squares up to a target. With hold instead, the part keeps the facing it has at `at` while the body moves under it, as a head stays level through a run. To turn the chest part of the way and the head the rest, aim the chest first with a weight, then the head. Written at every frame and then reduced to as few keys as keep it; the joint's motion outside the range and its blends is unchanged.

| Field | Type | Required | Description |
|---|---|---|---|
| `joint` | text | yes | Name of the driven part, for example RightUpperArm. |
| `time_from` | number, 0 to 300 | yes | Start of the range in seconds. In a looping clip it may be after time_to: the range then runs on past the end and round from the start, as a step that lands just after the loop begins (time_from 0.9, time_to 0.2), blends included. |
| `time_to` | number, 0 to 300 | yes | End of the range in seconds. Must not be past the end of the clip. In a looping clip, a range or blend that reaches the end, or the start, changes both alike, so the loop stays closed. |
| `target` | 3 numbers |  | The point to face, in studs from the root part: x toward the rig's right, y up, z toward its back. |
| `hold` | true or false |  | Keep the facing the part has at `at` instead of facing a point. |
| `at` | number, 0 to 300 |  | With hold: the time whose facing is kept. Default time_from. |
| `weight` | number, 0 to 1 |  | How much of the turn to make, from 0 to 1. Default 1. |
| `limit_degrees` | number, over 0, up to 180 |  | The most the joint is turned from its own motion, in degrees: a head that does not turn past its shoulder. |
| `blend_in` | number, 0 to 2 |  | Seconds before time_from over which it eases in. Default 0. |
| `blend_out` | number, 0 to 2 |  | Seconds after time_to over which it eases out. Default 0. |

#### overlap

Curve clips only. Follow-through and overlapping action: the joints named trail the motion they are given, through a damped spring, so a fast move pulls them along late and, with bounce, they swing on past where it stops before settling. An arm that trails a punch's turn, a head that lags a landing, hands that flap after a stop. Joints are taken from the body outward, each trailing a parent that already trails, and the lag is shared along them so the end of the chain trails by about `lag`. Over the whole of a looping clip, the motion comes back round to where it began. Written at every frame and then reduced to as few keys as keep it.

| Field | Type | Required | Description |
|---|---|---|---|
| `joints` | list of texts (1 to 32 items) | yes | The joints that trail, for example LeftUpperArm, LeftLowerArm and LeftHand, or Head. |
| `time_from` | number, 0 to 300 | yes | Start of the range in seconds. In a looping clip it may be after time_to: the range then runs on past the end and round from the start, as a step that lands just after the loop begins (time_from 0.9, time_to 0.2), blends included. |
| `time_to` | number, 0 to 300 | yes | End of the range in seconds. Must not be past the end of the clip. In a looping clip, a range or blend that reaches the end, or the start, changes both alike, so the loop stays closed. |
| `lag` | number, 0.02 to 0.5 |  | About how many seconds the end of the chain trails behind. Default 0.1. |
| `bounce` | number, 0 to 0.9 |  | How far it swings past where the motion stops: 0 trails without swinging past, 0.9 is very springy. Default 0.3. |
| `weight` | number, 0 to 1 |  | How much of the trailing to use, from 0 to 1. Default 1. |
| `blend_in` | number, 0 to 2 |  | Seconds before time_from over which it eases in. Default 0. |
| `blend_out` | number, 0 to 2 |  | Seconds after time_to over which it eases out. Default 0. |

#### place_on_floor

Curve clips only. Move the hips up or down at every frame of a range so that the body's lowest part rests on the floor, the rig's lowest point at rest, as validate_animation measures it. The whole body moves with the hips, feet and hands included, so place the body first and pin the feet after. The hips' position keys in the range are replaced by one key a frame, with smooth tangents; outside the range the clip is unchanged. The result counts frames_moved, with largest_raise_studs and largest_drop_studs.

| Field | Type | Required | Description |
|---|---|---|---|
| `time_from` | number, 0 to 300 | yes | Start of the range in seconds. In a looping clip it may be after time_to: the range then runs on past the end and round from the start, as a step that lands just after the loop begins (time_from 0.9, time_to 0.2), blends included. |
| `time_to` | number, 0 to 300 | yes | End of the range in seconds. Must not be past the end of the clip. In a looping clip, a range or blend that reaches the end, or the start, changes both alike, so the loop stays closed. |
| `mode` | one of `lift`, `touch` |  | lift (default) only raises a body that has gone into the floor, so a jump stays in the air. touch also brings a floating body down onto it: for lying, sitting, kneeling or a landing. |
| `parts` | list of any of `LowerTorso`, `UpperTorso`, `Head`, `LeftUpperArm`, `LeftLowerArm`, `LeftHand`, `RightUpperArm`, `RightLowerArm`, `RightHand`, `LeftUpperLeg`, `LeftLowerLeg`, `LeftFoot`, `RightUpperLeg`, `RightLowerLeg`, `RightFoot` (1 to 15 items) |  | The parts that rest on the floor. Default: every part but the lower legs. Parts are measured as boxes of their size with rounded corners, so for a body lying down, name the torso: the head's box is deeper than the torso and would hold the back off the floor. |
| `blend_in` | number, 0 to 2 |  | Seconds before time_from over which the move eases in. Default 0. |
| `blend_out` | number, 0 to 2 |  | Seconds after time_to over which it eases out. Default 0. |

#### clear_floor

Curve clips only. Keep a hand or foot off the floor over a time range: at every frame where its lowest point is nearer the floor than clearance, its limb lifts it straight up by the shortfall, turned as it was and where it was across the floor; frames where it is clear already are left as they are. A swinging foot that scuffs on its way to the next step, a hand that brushes the ground in a crawl or cartwheel. The floor is validate_animation's. Written at every frame and then reduced to as few keys as keep it. The result counts frames_lifted with largest_lift_studs.

| Field | Type | Required | Description |
|---|---|---|---|
| `part` | one of `LeftFoot`, `RightFoot`, `LeftHand`, `RightHand` | yes | The foot or hand to keep off the floor. |
| `time_from` | number, 0 to 300 | yes | Start of the range in seconds. In a looping clip it may be after time_to: the range then runs on past the end and round from the start, as a step that lands just after the loop begins (time_from 0.9, time_to 0.2), blends included. |
| `time_to` | number, 0 to 300 | yes | End of the range in seconds. Must not be past the end of the clip. In a looping clip, a range or blend that reaches the end, or the start, changes both alike, so the loop stays closed. |
| `clearance` | number, 0 to 2 |  | The least height of the part's lowest point above the floor, in studs. Default 0.05. |
| `blend_in` | number, 0 to 2 |  | Seconds before time_from over which it eases in. Default 0. |
| `blend_out` | number, 0 to 2 |  | Seconds after time_to over which it eases out. Default 0. |

## validate_animation

*Reads only: changes nothing in Studio.*

Check a working copy. Errors mean the clip is not structurally sound and cannot be saved: a pose for a joint the rig lacks, two keyframes at one time, two poses for one joint in a keyframe, numbers that are not finite or out of range. Warnings are measurements to look at and never stop a save: a looping clip whose last keyframe does not match its first, a joint moving faster than a limit between two keyframes, a joint driven through forces, content that is kept but not understood. In a curve clip, contact with the floor is also measured at every frame, the floor being the rig's lowest point at rest: a part below it (BELOW_FLOOR; parts are measured as boxes of their size with the corners rounded, as an R15 part's mesh is, and the lower legs, whose boxes reach down beside the ankle in a crouch, are left out), and, while a foot touches the floor (its lowest point no more than 0.4 of floor_studs above it), whether it moves across it, at whichever of its toe, heel and middle of the sole moves least, so a foot rolling over its toe or heel is not moving: fast at a frame (over 3 studs a second coming into it and going out of it) it scuffs (FOOT_SCUFF: a swinging foot that drags or a planted one that skates; each run of such frames is reported with its top speed), creeping for three frames or more it slides (FOOT_SLIDE). A foot passing a little above the floor, as a swing does, touches nothing. In a looping clip made on the spot, where planted feet move back steadily, the floor is taken to move with them, at the most common step of the soles on it, and feet are judged against it: a planted foot is fine, and a swing that skims the floor just before landing is still a scuff. Each finding has a code, the joints and times, the measured value and the limit. At most 50 are listed, with counts of all of them. These are measurements, not a judgement of how the motion looks.

| Argument | Type | Required | Description |
|---|---|---|---|
| `studio_session` | text | yes | Which Studio window to act in: a session id from get_workspace. |
| `clip_id` | text | yes | Working copy id from open_animation or get_workspace. |
| `thresholds` | object |  | Limits to use in place of the defaults. |
| `thresholds.loop_rotation_degrees` | number, over 0 |  | How far a looping clip's last keyframe may be from its first, per joint. Default 2. |
| `thresholds.loop_position_studs` | number, over 0 |  | The same for position. Default 0.02. |
| `thresholds.speed_degrees_per_second` | number, over 0 |  | How fast a joint may turn between two keyframes. Default 2000. |
| `thresholds.speed_studs_per_second` | number, over 0 |  | How fast a joint may move between two keyframes. Default 40. |
| `thresholds.floor_studs` | number, over 0 |  | Curve clips: how far a part may go below the floor; a foot within 0.4 of this above it touches the floor. Default 0.1. |
| `thresholds.slide_studs` | number, over 0 |  | Curve clips: how far a planted foot may slide. Default 0.1. |

## save_animation

Save a copy of a working copy as a new clip for its rig, where Roblox's Animation Editor keeps that rig's clips, so that it can be loaded in the editor. The working copy stays open and unchanged. Nothing already saved is replaced: a name that is taken is refused. A clip with structural errors (see validate_animation) is refused; warnings never stop a save. One Studio undo removes the saved clip. With replace_source, nothing is saved: instead a person in Studio is asked whether the clip the working copy was opened from may be replaced by it, and the result says pending, approved or rejected. Call again with the same revision to see the outcome.

| Argument | Type | Required | Description |
|---|---|---|---|
| `studio_session` | text | yes | Which Studio window to act in: a session id from get_workspace. |
| `clip_id` | text | yes | Working copy id from open_animation or get_workspace. |
| `expected_revision` | text | yes | Revision from the last read or edit of this clip. |
| `name` | text, 1 to 100 characters |  | Name for the saved clip. Default: the working copy's name. |
| `replace_source` | true or false |  | Propose replacing the clip this working copy was opened from, in place of saving a new one. Only a person can approve it, in the Keywright panel. Refused with SOURCE_CHANGED if that clip has changed since the working copy was opened. A rejection stands for that revision. |

## discard_animation

Remove a working copy that is no longer needed. Saved clips are not affected. One Studio undo brings the working copy back.

| Argument | Type | Required | Description |
|---|---|---|---|
| `studio_session` | text | yes | Which Studio window to act in: a session id from get_workspace. |
| `clip_id` | text | yes | Working copy id from open_animation or get_workspace. |
| `expected_revision` | text | yes | Revision from the last read or edit of this clip. |

## preview_animation

*Reads only: changes nothing in Studio.*

Sample a working copy at an exact time and report the joint transforms. The clip is evaluated on a disposable copy of the rig; the rig itself and the camera are never moved. To see the pose, pass render: true: the result then includes a schematic picture drawn from the sampled joint positions, with each part as a box, the rig's left side blue and its right side orange, and a dark mark on the front of the head. It shows the pose, not the rig's real appearance, and is not a Studio screenshot. Studio screenshots (capture: true) are off by default and return capture.status "unavailable" with the reason.

| Argument | Type | Required | Description |
|---|---|---|---|
| `studio_session` | text | yes | Which Studio window to act in: a session id from get_workspace. |
| `clip_id` | text | yes | Working copy id from open_animation or get_workspace. |
| `time` | number, 0 to 300 |  | The time to sample, in seconds. Give this or times. |
| `times` | list of numbers, 0 to 300 (2 to 8 items) |  | Several times to sample in one call, in place of time (with interrupt, seconds after the interruption). With render, the picture is a filmstrip: one column for each time in the order given, one row for each view (at most two), all framed alike so that what moves can be seen. The result lists the frames in the same order. |
| `samples` | whole number, 9 to 48 |  | In place of time or times: follow parts over the whole clip, at this many moments evenly spread. The parts are those in track, or the hands, feet, head and hips. The result has motion: for each part, how far it travels (path) and ends from where it began (net); how low its lowest point comes (lowest, measured as validate_animation does) and when (lowest_time); its top speed and when; when it starts and stops moving; holds, the stretches in between where it stands still; the largest change of speed from one moment to the next and when; and bow, how far its path strays from a straight line. Parts that all start and stop together move as one block; a large speed jump is a corner in the motion; no bow is a straight line. With render, the picture shows each part's path over the rig, a dot at every sample, beside a chart of each part's speed across the clip. |
| `render` | true or false |  | Include a schematic picture of the pose, drawn from the sampled joint positions. |
| `views` | list of any of `front`, `back`, `left`, `right`, `top`, `three_quarter` (1 to 4 items) |  | Directions to draw the pose from, side by side. Default ["three_quarter"]. "left" and "right" are the rig's own sides. |
| `render_size` | whole number, 128 to 768 |  | Height of the picture in pixels; each view is square. Default 384. |
| `style` | one of `boxes`, `slim` |  | How the picture draws the rig. "boxes" (default) draws every part as a box of its size: best for contact with the floor and for parts passing through each other. "slim" draws the arms and legs thin along their length, keeping the hands, feet, torso and head as boxes: best for reading limb angles, elbow and knee bends, and arm swings, which bulky boxes hide. |
| `onion` | true or false |  | With times and render: draw the moments over each other in one picture for each view (at most two), the last solid and earlier ones fainter the earlier they are, instead of a filmstrip. Each part in track has its whole arm or leg drawn stronger and its path drawn through the frames, a dot at each numbered in the order of the times. Shows how a limb travels between poses: where an elbow turns round, whether a fist or foot moves in an arc. Pass a few neighbouring times, 3 to 7, and one or two tracked parts; slim style reads best. |
| `capture` | true or false |  | Ask for a Studio screenshot. Off unless approved in Studio; see the tool description. |
| `max_edge` | whole number, 64 to 1536 |  | Longest edge of the screenshot in pixels. Default 768. |
| `joints` | list of texts (up to 32 items) |  | Joints to sample. Default: none. |
| `compare_with` | text, up to 120 characters |  | With times: also sample another clip of the same rig at the same times. "source" is the clip this working copy was opened from, "saved:" followed by a name is one of the rig's saved clips, anything else is the id of another working copy. The result gains compared: for each time, the largest distance in studs and turn in degrees between where the two clips put the rig's parts, and the part furthest apart. With render, the picture has this clip along the top row and the other along the bottom. |
| `interrupt` | object |  | With times: show this clip being interrupted by another, as a game does when a player blocks partway through a jab. Both clips are played by Roblox's animation engine on a disposable copy of the rig: this one from at, the other started with a fade while this one is stopped with the same fade, both advancing in real time, blended by their weights and priorities. times are then seconds after the interruption (0, 0.033, 0.067, 0.1, 0.133 covers a 3-frame fade and a frame after). Each frame gains this_time and other_time, each clip's own time, and weights, each track's weight as the engine reports it; the result's interrupt gives both priorities. track, measure, render, style and onion work as with times alone: watch a wrist that cuts through the face or a planted foot that shifts during the blend, which each clip on its own would not show. Not with compare_with. |
| `interrupt.clip` | text, 1 to 120 characters | yes | The clip that interrupts this one, named as compare_with names one: "source", "saved:" and a saved clip's name, or a working copy's id. Same rig. |
| `interrupt.at` | number, 0 to 300 | yes | When in this clip the other starts, in seconds: a jab's frame 6 is 0.2. |
| `interrupt.fade` | number, 0 to 2 | yes | Seconds over which this clip fades out and the other fades in: 3 frames is 0.1. |
| `interrupt.from` | number, 0 to 300 |  | Where in the other clip it starts, in seconds. Default 0. |
| `compare_times` | list of numbers, 0 to 300 (2 to 8 items) |  | With compare_with: the other clip's own times, one for each of times, in the same order, for when a move has been retimed. Each column then pairs this clip at a time in times with the other clip at its time here: an impact on frame 11 now with an impact on frame 8 before. To line clips up by a marker, read both clips' marker times with read_animation and pass them. The bottom row is labelled with these times, and each entry of compared gains other_time. |
| `track` | list of texts (up to 15 items) |  | Parts whose place in the rig to report as numbers, for example LeftFoot and RightFoot. Each gets position (x toward the rig's right, y up, z toward its back; forward is negative z), in studs from the root part, and lowest, the height of its lowest point, measured as validate_animation does: a box of the part's size with its corners rounded. With times, each frame after the first also has velocity (studs per second along x, y, z since the frame before) and speed, and the result has ranges: for each part, the least, greatest and difference of x, y, z and lowest over the frames. A foot that is planted keeps the same lowest; in a cycle made on the spot it moves steadily backward while planted. |
| `measure` | list of objects (1 to 4 items) |  | Measure one part from another, or from the root part, along one of the rig's directions, at every time sampled (with time, times or samples). The parts are tracked for you. The result has measured: for each measurement, values (time and studs at each moment), least and greatest (each with its time), and change, the difference between them. Examples: how far a fist reaches past the head at impact ({part: "RightHand", relative_to: "Head", along: "forward"}, with the impact's time among times); how low the hips sink after a foot lands and when they are lowest ({part: "LowerTorso", along: "up"}); how far a planted foot drifts ({part: "LeftFoot", along: "forward"} over its stance). To read a value at a marker, include the marker's time in times. |
| `measure[].part` | text, 1 to 64 characters | yes | The part measured, for example RightHand. |
| `measure[].relative_to` | text, 1 to 64 characters |  | The part it is measured from, for example Head. Default: the root part. |
| `measure[].along` | one of `forward`, `up`, `right`, `distance` | yes | "forward" (toward where the rig faces at rest), "up" or "right" (the rig's right), each in the rig's own directions, or "distance", the straight-line distance. |
| `check_placement` | true or false |  | A check on Studio itself, not needed for animating. Also compare where Studio put each part of the disposable copy with where the joint transforms say it should be. The result then includes placement: the number of parts compared, the largest difference in studs and in degrees, and the part it was on. |
