# Reviewing an animation

You can't watch the animation play. You review it three ways, and each catches what the
others miss.

| Tool | Shows | Misses |
|---|---|---|
| Pose strip: `preview_animation` with `times` and `render: true` | Whether each pose reads, silhouettes, clipping, balance | Timing and spacing between the frames |
| Motion plot: `preview_animation` with `samples` and `render: true` | Paths, speed over time, holds, pops, straight lines | Whether any pose reads |
| Numbers: `track`, `compare_with`, `validate_animation` | Exact heights, positions, differences, contacts | Everything about taste |

## Pose strips

- Use the times of your key poses, not evenly spaced times: the key poses are what must read.
- Choose views by the action: `right` or `left` (the rig's own sides) for anything moving
  forward and back; `front` for gestures and side-to-side; `top` for spins and turns;
  `three_quarter` for an overall look. Up to two views side by side.
- The rig's left side is blue and its right side orange, and the mark on the head is its
  front. Check you're animating the side you meant.
- `compare_with` draws another clip along the bottom row at the same times, and reports
  the largest distance between the two at each. Compare each revision with the last, and
  your work with the source clip.

## Motion summary

With `samples`, each tracked part (by default the hands, feet, head and hips) reports:

| Field | Means | Look for |
|---|---|---|
| `holds` | Stretches where the part stands still | Holds you didn't plan; many parts holding at once |
| `starts`, `stops` | When it first and last moves | Parts that all start and stop together move as one block |
| `peak_speed`, `peak_time` | Its fastest moment | Every part peaking at the same moment means no overlap |
| `largest_speed_jump` | The biggest change in speed between samples | A pop or a corner |
| `bow` | How far its path strays from a straight line | Zero for a hand or foot: a straight, mechanical path |
| `path`, `net` | How far it travels, and ends from its start | `net` not zero in a loop: it doesn't come back |
| `lowest`, `lowest_time` | The lowest its lowest point gets | Below the floor, or a foot never reaching it |

In the speed chart, a good move is a rounded hump: speed builds and bleeds off. Rectangles
(constant speed that starts and stops on keys) look mechanical. Speeds step every 1/30 s
in curve clips: that is Studio's frame rate, not a problem.

## Validation findings

`validate_animation` errors stop a save; fix them. Warnings are measurements:

| Finding | Usually means | Fix |
|---|---|---|
| `FOOT_SLIDE` | A planted foot creeps | `pin` it over its stance (with `travel` in a cycle made on the spot) |
| `FOOT_SCUFF` | A foot drags while moving fast near the floor: often a swing skimming just before landing | `clear_floor` on the swing, or swing the foot higher |
| `BELOW_FLOOR` | A part goes into the floor | `place_on_floor`, or raise the hips at that time, or bend the knees |
| `LOOP_ROTATION_MISMATCH`, `LOOP_POSITION_MISMATCH` | The last pose differs from the first | `copy_pose` the first frame to the last |
| `ABRUPT_ROTATION`, `ABRUPT_MOVE` | A joint moves very fast | Meant on a snap or strike; otherwise space the keys out or ease them |
| `KEY_OFF_FRAME` | Curve keys between frames | Move them onto multiples of 1/30 s |

## Symptoms and fixes

| It looks... | Likely cause | Try |
|---|---|---|
| Stiff, robotic | Even spacing, linear motion, everything moving together | Ease into and out of key poses; offset parts by 2–4 frames; add `overlap` |
| Frozen in places | Every part easing to rest at the same moment | Keep something moving through holds; offset the settles |
| Floaty | Too slow, or too even, especially falls and landings | Fewer frames on the fall, faster into contact, a stronger absorb |
| Weightless | No anticipation, no absorb, hips not over the support | Add a load before and a settle after; fix the balance in the key poses |
| Popping | A key far from its neighbours, or a joint flipping through a big angle | Look at the motion plot's speed jump; add a breakdown key or reduce the angle |
| Swimming | Too much `overlap`, or noise on everything | Lower the lag or weight; keep noise on a few joints |
| Like a pendulum | Limbs swinging from one joint only | Bend the next joint too: elbows with shoulders, knees with hips |
| Unreadable | Weak silhouette, wrong view, or the pose undersold | Exaggerate the key pose; check another view; strengthen the line of action |
| Sliding feet | Planted feet not pinned, or pin ranges too long | `pin`; end pins where the foot lifts, and don't blend out while it's still down |
