---
name: keywright
description: Use when making or revising a Roblox animation with the Keywright MCP tools (get_workspace, open_animation, edit_animation, preview_animation, validate_animation, save_animation). Covers planning key poses, blocking, reviewing poses and timing with pose strips and motion plots, contacts and loops, and knowing when an animation is done.
---

# Animating with Keywright

Keywright's tools can make any motion; whether it reads as the motion asked for depends on
how you direct it. Work the way an animator does: plan the key poses, block them, look,
then refine. The tools check structure and measure motion. Only looking at the poses tells
you whether the animation works.

## 1. Understand the request and the rig

- Call `get_workspace`, then `inspect_rig` for the rig you'll animate. Its `turns` say where
  the far end of each part moves for a positive rotation about X, Y and Z, so you don't
  have to find directions by trial.
- Settle what was asked: the length, whether it loops, the mood, and anything that must
  stay still. Ask if it's unclear rather than guess.
- Choose the clip kind. Curve clips (`format: "curves"`) carry speed through keys, and suit
  motion that flows: walks, runs, idles, strikes. Keyframe clips suit simple posed moves and
  are the Animation Editor's usual form. Curve clips play at 30 frames a second, so put keys
  on whole frames (multiples of 1/30 s).

## 2. Plan before editing

Write the plan down before the first edit. For each key pose: its time, and what it must
read as in silhouette. For example, a front kick:

| Time | Pose | Must read as |
|---|---|---|
| 0.00 | Guard | Weight on both feet, fists up |
| 0.20 | Chamber | Knee up high, foot tucked, hips starting to turn |
| 0.30 | Contact | Leg fully extended, hips turned over, body leaning back to balance |
| 0.45 | Recoil | Knee comes back toward the chest, **not** straight down |
| 0.70 | Guard | Foot planted, back to the first pose |

Also plan:
- **Anticipation:** a small move the other way before the big one, such as a dip before a jump.
- **The line of action:** one curve through the spine and limbs, especially at contact poses.
- **Timing:** fast where the force is (the strike), slower where the weight settles (the recovery).
- **Asymmetry:** the two sides doing the same thing at the same time looks mechanical. Offset
  them by a frame or two, or give them different amounts.

## 3. Block the key poses

- `open_animation` a blank clip, or a copy of a clip to start from.
- Key only the key poses first, with `set_key` (curves) or `set_pose` (keyframes). Batch the
  whole blocking pass into one `edit_animation` call where you can.
- Joints carry a pose relative to their parent, so pose from the hips outward:
  `LowerTorso`, then `UpperTorso`, then the head and limbs.
- A turn that goes the wrong way on a joint already turned a lot, such as a raised arm, can
  come from the order the angles are applied in (X, then Y, then Z). `offset_pose` (keyframes)
  or `add_offset` (curves) adds a turn on top of the existing pose, which is often what you
  mean. Check with a pose strip.

## 4. Look at the key poses

After the blocking pass, and **after every revision**:

- **Pose strip:** `preview_animation` with `times` at the key moments, `render: true`, and a
  view that shows the action: `right` or `left` for kicks, walks and jumps, `front` for
  waves and side steps. Two views side by side help. Ask of each frame: does it read as what
  the plan says? Is the silhouette clear? Are hands, feet and head where they should be?
- **Compare with the last version:** `compare_with` shows the earlier clip along the bottom
  row, and gives the largest distance between the two at each time. Use it to confirm a
  revision changed what you meant, and nothing else.
- **Numbers, when the picture isn't enough:** `track` reports where parts are, and the
  height of their lowest point. Use it for feet on the floor, a hand reaching a target, or
  clearance from the head.

A pose that doesn't read is a planning problem as much as an editing one. Fix the key pose
before adding detail.

## 5. Refine the motion

- **Motion plot:** `preview_animation` with `samples` (24 to 48) and `render: true` draws each
  part's path and speed across the clip. Read it for:
  - `holds` you didn't plan: everything stopping at once looks robotic;
  - a large `largest_speed_jump`: a pop or a corner;
  - `bow`: zero is a straight line, but arms and legs move in arcs;
  - parts that start and stop together: offset them.
- Add in-betweens where a move needs a different path or spacing, not everywhere.
- **Curve clips:** run `auto_tangents` after keying. Use `snap_at` for strikes that should
  arrive fast and stop dead. Use `overlap` to let arms, hands and the head trail a big move
  and settle. Use `add_noise` for life in a hold or an idle.
- **Keyframe clips:** easing belongs to the pose a stretch *starts* from. `smooth_motion`
  turns blocked keys into one flowing curve.

A speed plot can't tell you whether a pose reads, and a pose strip can't show timing. Use
both.

## 6. Contacts and loops (curve clips)

- **Order:** body first, then feet. `place_on_floor` sets the hips height; then `pin` holds
  the feet, which keeps them planted while the hips move. `clear_floor` lifts a swinging
  foot that scuffs.
- **Walks and runs made on the spot:** pin each foot over its stance, with `travel` (or
  `travel: "match"`) so the planted foot moves back steadily under the body.
- **Loops:** `copy_pose` ends the clip in exactly its first pose. `mirror` with an offset of
  half the clip's length makes the second half of a cycle from the first. `shift_time` with
  `wrap` moves where the loop starts.

## 7. Check, and know when it's done

- `validate_animation`, or `validate: true` on an edit. Errors stop a save. Warnings are
  measurements: a strike's speed warning can be meant, but a foot sliding in a walk usually
  isn't.
- **Passing validation is necessary, not enough.** It's done when:
  - every key moment reads in the pose strip as the plan says;
  - the motion has no stops or pops you didn't plan;
  - feet that should stay planted do, and nothing sinks into the floor;
  - a loop closes;
  - you've looked at a pose strip of the *final* version.

## 8. Save and hand over

- `save_animation` under a new name. Saving never overwrites. To replace one of the person's
  clips, use `replace_source` only when they asked, and they approve it in Studio.
- Tell the person what you made, the key poses and their timing, and what you weren't sure
  about. Ask them to play it in the Animation Editor: the pictures are schematics, so the
  final judgement of how it looks is theirs.
- When they ask for changes, edit your working copy, save under a new name, and review it
  again as in step 4.
