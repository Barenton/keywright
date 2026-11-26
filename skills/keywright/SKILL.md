---
name: keywright
description: Use when making or revising a Roblox animation with the Keywright MCP tools (get_workspace, inspect_rig, open_animation, edit_animation, preview_animation, validate_animation, save_animation). Teaches an animator's workflow on Keywright's tools - planning key poses, blocking, reviewing poses and timing, body mechanics, contacts and loops, and knowing when an animation is done.
---

# Animating with Keywright

Keywright gives you exact control of every joint and good ways to measure the result. It
does not give you taste: a clip can pass every check and still look stiff, floaty or wrong.
Animate as a professional does: **plan the poses, block them, look, refine, look again.**
Never trust a clip you have not looked at.

This file is the workflow. Open the references when you need them:
- [reference/rig.md](reference/rig.md): which way R15 joints turn, how to build common
  poses, and the traps (angle order, rest poses, the floor).
- [reference/moves.md](reference/moves.md): timing and method for walks, runs, idles,
  gestures, strikes, jumps, hit reactions, falls and get-ups.
- [reference/review.md](reference/review.md): reading pose strips, motion summaries and
  validation findings, and what to change for each symptom.

## The workflow

### 1. Understand the request

- Find out the length, whether it loops, the mood ("tired", "snappy", "heavy"), and
  anything that must stay still or line up with gameplay (a hit at a given moment, a
  marker name). Ask when it matters and you can't infer it.
- `get_workspace` for the rig, then `inspect_rig`. Read its `turns`: they say where each
  part's far end moves for a positive rotation about X, Y and Z on *this* rig.
- If the person has a clip to start from (a guard pose, an earlier version), open a copy
  of it: shared start poses make a set of moves blend together.
- **Ask whether there's an animation they like** of the same kind. Read its keys with
  `read_animation` and compare ranges with yours: how far each joint swings, how bent it
  stays, how far the body leans. It's the quickest way to see what makes theirs work.

### 2. Plan before the first edit

Write the plan out, in your reply or your notes, before editing:

1. **The beats:** the story of the move in a few words each. A heavy punch: load, drive,
   impact, recoil, settle.
2. **The key poses:** one per beat, each with its time (in frames at 30 a second) and
   what it must **read as** in silhouette. "Impact: arm fully extended in line with the
   shoulders, hips and chest turned through, weight on the front foot, rear heel lifted."
3. **The timing:** where the motion is fast (the drive) and slow (the settle). Fast moves
   take few frames; weight takes time to arrive and to leave.
4. **The contacts:** which feet and hands touch the floor, and when they plant and leave.
5. **The clip kind:** curve clips (`format: "curves"`) for nearly everything that flows;
   keyframe clips only for simple posed moves or when the person needs that form.

### 3. Block the key poses

- One `edit_animation` batch for the whole blocking pass where you can. A batch holds up
  to 256 operations; dense clips take several calls.
- Pose **from the hips outward**: `LowerTorso` (the hips carry the weight and lead most
  moves), then `UpperTorso`, then the head, then the limbs, then the hands and feet.
- Key **only** the key poses. Don't add in-betweens yet: you'll want to move the keys.
- Curve clips: keys on whole frames (multiples of 1/30 s), written exactly: `0.0333333`,
  `0.6666667`, not `0.033` or `0.667`, which land between frames. A joint first keyed
  later than 0 starts from its rest pose at 0; key it at 0 too if it should start
  somewhere else.

### 4. Look at every key pose

`preview_animation` with `times` at every key pose, `render: true`, `style: "slim"` (thin
limbs, so angles and bends read), and the view that shows the action (side for kicks, walks and jumps; front for waves and side steps; two
views side by side for anything that turns). For each frame, ask:

- Does it read as what the plan says, in silhouette alone?
- Is the **line of action** clear: one curve through the spine into the limbs?
- Is the **weight** believable: the hips over the supporting foot, or deliberately off
  balance and about to fall or step?
- Are the hands, feet and head where they should be, and not inside the body?
- **Judge the upper and lower body separately.** Look at only the legs and hips, then only
  the chest, head and arms. Good legs hide weak arms, and the other way round.

Fix the key poses until every one reads. **Detail never rescues a weak pose.**

### 5. Refine the motion

Now make it move well between the poses. Check each with the motion plot
(`preview_animation` with `samples` 24–48 and `render: true`):

- **Easing, not extra keys.** Let speed build into a strike and bleed off after it. Many
  keys at even spacing look mechanical; a few well-placed keys with good tangents look alive.
  Curve clips: `auto_tangents`, with `snap_at` on impacts that should arrive fast and stop
  dead.
- **Overlap and follow-through.** Parts arrive at different times: hips first, then chest,
  then shoulders, head, arms, hands. Offset them by **2–4 frames**: one frame (0.03 s)
  doesn't read as overlap. `overlap` makes arms, hands and the head trail a move and settle.
- **Never stop everything at once.** A whole body easing to rest together reads as a
  freeze. In a hold, keep something drifting: breathing, a slow settle, the head adjusting.
- **Arcs.** Hands, feet and the head travel in curves. A path with no bow is a straight,
  robotic line. An onion skin (`onion: true`) of the move shows the arc and where each
  limb turns round.
- **No stops mid-swing.** A limb that comes to rest at a key in the middle of a swing, then
  whips on, pops. Put each swing's extreme where the limb really turns round (a runner's
  thigh, just after toe-off), and let the keys either side carry it through. A large
  `largest_speed_jump` in the motion summary points at it.
- **Anticipation.** A small move the opposite way before a big one: a dip before a jump, a
  draw back before a punch, a lean before a run.
- **Asymmetry.** Mirror-image poses, both sides doing the same thing at once ("twinning"),
  look stiff. Vary the amounts, offset the timing.
- **Exaggeration.** On a blocky rig, poses read better pushed further than feels natural.

### 6. Contacts and the floor (curve clips)

Body first, then feet: `place_on_floor` sets the hips height; then `pin` holds each foot
while it's planted; `clear_floor` lifts a swinging foot that scuffs. Re-check the feet
after **any** change to the hips or legs. If `pin` reports frames out of reach, the hips
are too far from the foot there: lower them, end the pin earlier, or roll the foot onto
its toe (`pivot: "toe"`) for the last frames of the stance. Details for walks, landings
and kneeling are in [reference/moves.md](reference/moves.md).

**Weight on landing.** For every landing (each step of a walk or run, a jump, a fall),
`measure` `{part: "LowerTorso", along: "up"}` through it: the hips must keep going down for 2–3 frames after the
foot touches, be lowest then, and not hold still while the foot is planted. Hips that are
lowest at the moment of contact, or still through the stance, make the body bounce off the
floor as if it weighed nothing.

### 7. Check, review, and know when it's done

Run `validate_animation`, then review the final version as a whole:

1. A **pose strip** of every key moment, from the views that matter.
2. A **motion plot** of the whole clip.
3. `compare_with` the previous version, so the revision changed what you meant and nothing else.

It's done when **all** of these hold:
- Every key moment reads in the strip as the plan says.
- The motion has no stops, pops or straight lines you didn't plan.
- Planted feet stay planted, nothing sinks into the floor, and swinging feet clear it.
- A loop closes: last pose equals first.
- Every landing absorbs: the hips are lowest 2–3 frames after contact (checked with `measure`).
- No limb stops mid-swing: no large speed jump you didn't plan in the motion summary.
- `validate_animation` has no errors, and every warning is one you meant. A strike's
  speed can be meant; a sliding foot in a walk isn't.
- You have looked at a strip of the **final** revision, not an earlier one.
- You've run `reduce_keys` over the clip, so a person can still edit its curves.

### 8. Save and hand over

- `save_animation` under a new name. Never replace the person's clip unless they ask;
  then they approve it in Studio.
- Report the beats and key poses with their timing, what you weren't sure of, and what
  you'd try next. Ask the person to play it in the Animation Editor: pose pictures are
  schematics, so how it really looks is their call.
- On feedback, edit the working copy, then repeat steps 4–7 on the parts that changed.

## If Studio refuses a change

`STUDIO_NOT_IN_EDIT_MODE` means Studio wouldn't start an undo step, so Keywright made no
change. Ask the person to close the Animation Editor, especially if it's playing a clip,
then try again. If that isn't it, something else is in progress in Studio, such as a
dialog or a drag.

## Habits that separate good results from bad

- **Look after every change.** Revisions break things away from where you were working.
- **Change one thing at a time** when fixing, then look, so you know what fixed it.
- **Use numbers to settle what pictures can't:** `measure` for a reach, a height or a drift
  between parts, `track` for a part's position, `compare_with` for exactly how much changed.
- **Reuse.** Start related moves from one shared pose; build cycles from half a cycle with
  `mirror`; close loops with `copy_pose`.
- **Keep keys editable.** After `pin`, `aim`, `overlap` or `add_noise` write a key every
  frame, run `reduce_keys` so a person can still work with the curves.
