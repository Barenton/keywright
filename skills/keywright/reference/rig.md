# Posing an R15 rig

## The joints

An R15 rig has 15 animated joints, each named after the part it moves:

| Body | Joints, from the root out |
|---|---|
| Spine and head | `LowerTorso` (the hips), `UpperTorso` (the chest), `Head` |
| Each arm | `LeftUpperArm`, `LeftLowerArm`, `LeftHand` (and the same for `Right`) |
| Each leg | `LeftUpperLeg`, `LeftLowerLeg`, `LeftFoot` (and the same for `Right`) |

A pose's rotation is **relative to the part's parent** and to the rest pose: zero means
"as at rest". Moving `LowerTorso` moves everything; moving `UpperTorso` moves the chest,
head and arms.

## Which way joints turn

Always read `inspect_rig`'s `turns` for the rig in front of you. On the standard R15 rigs
measured so far, they were:

| Joints | +X | +Y | +Z |
|---|---|---|---|
| Arms, legs, hands, feet | far end moves **forward** | twist about the part's length | far end moves to the rig's **right** |
| `LowerTorso`, `UpperTorso`, `Head` | top moves **back** | twist | top moves to the rig's **left** |

What follows from that:

| To do this | Turn |
|---|---|
| Raise the right arm out to the side | `RightUpperArm` +Z (90 = horizontal) |
| Raise the left arm out to the side | `LeftUpperArm` −Z |
| Raise an arm forward | the upper arm +X |
| Bend an elbow with the forearm forward | the lower arm +X |
| Lift a knee forward | the upper leg +X |
| Bend a knee (shin back) | the lower leg −X |
| Lean the body forward | `LowerTorso` or `UpperTorso` −X |
| Tilt the head toward the right shoulder | `Head` −Z |

Check every new pose in a pose strip anyway: these are a starting point, not a guarantee.

## Positions

`position` offsets a joint from its rest place, in studs, in the parent's frame. On the
hips (`LowerTorso`) it moves the whole body: lower it for a crouch, raise it for a jump.
Other joints rarely need positions.

## Traps

- **Angle order.** A rotation is applied as X, then Y, then Z. On a joint already turned
  far, such as an arm raised 90° to the side, a further X turn may not go where you
  expect: it can tip the raised forearm backward instead of forward. `offset_pose`
  (keyframes) or `add_offset` (curves) adds a turn on top of the existing pose, in the
  joint's own frame, which is often what you mean. Look before moving on.
- **Rest poses differ.** Two rigs can be different bodies (a few tenths of a stud apart).
  Numbers from one rig are a start on another, not an answer; check the pictures.
- **Lying down.** With the hips tilted back about 90° (`LowerTorso` +X 88), the legs lie
  flat along the floor at about 0 relative, not 90: they follow the hips.
- **The floor** is the rig's lowest point at rest. A crouch that lowers the hips without
  bending the knees pushes the feet into it; bend the knees as the hips drop, or `pin` the
  feet `on_floor`.
- **Reach.** A straight leg can't reach a foot planted far from the hips. Lower the hips,
  bend the knee, or let `pin` `fit_hips` lower them just enough.
- **Hands in the head.** Raised hands near the face often clip into the head's box. A
  pose strip from the front shows it. Bring the arm forward, or shorten the swing.
- **Twist.** +Y turns a part about its own length. Use it to turn a palm, a foot's toe
  out, or the head to look aside.

## Shaping good poses

- **Weight:** the hips sit over the foot carrying the weight. On two feet, between them,
  nearer the one with more weight. A leaning body needs a foot under it, or it's falling.
- **Contrapposto:** when the hips tilt one way, the shoulders tilt the other. A relaxed
  stance almost never has level hips and shoulders.
- **Line of action:** at the strongest moment of a move, one smooth curve runs from the
  planted foot through the spine to the striking hand or foot.
- **Silhouette:** hold the pose in your head as a black shape. Arms in front of the body
  disappear; spread them, or pick the view where they read.
- **Breaking symmetry:** different elbow bends, one shoulder higher, the head turned a
  little. Symmetric poses look like a mannequin.
- **Guard and idle stances:** knees soft (lower legs −10 to −20 X), feet apart, hips down a
  little, weight on the balls of the feet.
