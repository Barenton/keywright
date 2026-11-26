# Building common moves

Times are in frames at 30 a second (Studio plays curve clips at 30). These are starting
points from moves that worked; adjust them to the mood asked for. Faster reads as lighter
and snappier, slower as heavier or tired.

## Strikes: punches and kicks

| Beat | Punch (frames) | Kick (frames) | Notes |
|---|---|---|---|
| Guard | 0 | 0 | Start from a shared guard pose so moves chain |
| Anticipation / load | 3–6 | 4–6 | Hips turn back, weight shifts, fist draws or knee lifts into the chamber |
| Drive | 2–4 | 2–4 | Fast. Hips lead, then chest, then the arm or leg |
| Impact | hold 1–3 | hold 1–3 | Fully extended, the line of action through the whole body |
| Recoil | 4–8 | 4–8 | Retract along a **different path** from the strike, not straight back |
| Settle to guard | 6–12 | 8–14 | Slow; overshoot a little and settle |

- The hips start the move and the fist or foot finishes it: offset hips, chest, upper arm,
  forearm and hand by 2–3 frames each.
- `snap_at` the impact key on the striking limb (curve clips), so it arrives fast and
  stops dead. Expect a speed warning there; it's meant.
- A kick's **chamber** (knee up, foot tucked) comes before the extension and again before
  the foot comes down. Without the second, the leg swings like a pendulum.
- The non-striking arm guards the face or pulls back to balance the strike.
- Keep the planted foot pinned; let the rear heel lift on a punch (`pin` with `pivot: "toe"`).

## Walk cycle (looping, made on the spot)

- **Length:** 30 frames (1 s) for a normal walk; 36–40 for slow or tired; 24 for brisk.
- **Key poses** for one leg, over half the cycle: contact (heel down, leg forward), down
  (weight lands, knee bends, hips lowest), passing (the swinging leg passes the standing
  one, hips highest), up (pushing off the toe).
- **Build:** key one side (one leg and the opposite arm) over the whole cycle; `copy_pose`
  the first frame to the last; then `mirror` `left_to_right` with `offset` half the cycle
  builds the other side.
- **Hips:** they rise and fall twice per cycle (lowest just after each contact) and sway
  toward the standing leg. `place_on_floor` with `mode: "touch"` gives the bob from the
  legs; adjust with `add_offset`.
- **Feet:** pin each foot over its stance with `travel` (or `travel: "match"`), since on the
  spot the planted foot moves back steadily under the body. Roll it: `pivot: "heel"` with a
  small `roll` as it lands, flat, then `pivot: "toe"` with `roll` up to 20–30 as it pushes
  off. Swing the foot ahead in the air and let it pull back as it lands, so it meets the
  floor moving with it. `clear_floor` (clearance 0.05–0.1) on the swing stops scuffs.
- **Hip height** trades reach against clearance: too high and the planted leg can't reach
  (`pin` reports frames out of reach); too low and the swinging foot scuffs.
- **Upper body:** arms swing opposite the legs, with `overlap` on the forearms. The chest
  turns opposite the hips. `aim` with `hold` steadies the head.
- **Check:** a pose strip at contact, down, passing and up from the side; `validate` for
  `FOOT_SLIDE` and `FOOT_SCUFF`; a motion plot for even speed through the cycle; and `track`
  `LowerTorso` at every frame of one step: lowest 2–3 frames after contact, never holding.

## Run cycle

- 14–20 frames. Faster and longer flight than a walk, with **no** frame where both feet
  touch: each foot's stance is short, and both are in the air between.
- A forward lean (hips and chest −X, about 10–15° together) with the head tipped back to
  stay level, the chest twisting against the hips, arms pumping in arcs with the elbows
  bent near 90°.
- **The hips' height over one step** (contact at frame 0, a 10-frame step): coming down
  at contact, still sinking for 2 frames (the absorb, lowest at frame 2), rising through
  push-off, highest in mid-flight, falling to the next contact. Key the hips' position
  and run `auto_tangents` on them; don't leave it to the legs.
- **The stance:** pin the foot flat from contact for about two-thirds of the stance, then
  `pivot: "toe"` with a `roll` of 25–35 for the push-off, both with the same `travel`.
  Pinning flat through toe-off leaves the leg out of reach as the hips rise.
- **The swing:** the thigh turns round just after toe-off and swings forward smoothly; it
  must not stop partway. The knee folds as the foot passes under the body, the foot well
  clear of the floor (a few tenths of a stud on a standard rig), then the leg reaches
  forward and pulls back so the foot lands moving with the floor.
- Build the cycle as for a walk.
- **Check:** `track` `LowerTorso` over a step (lowest 2–3 frames after contact); `track`
  the feet at passing for clearance; the motion summary for a speed jump in the feet (a
  thigh stopping mid-swing); and that the head doesn't simply ride the hips (`aim` with
  `hold`, about half weight, steadies it).

## Idle

- 2–4 s loop. The body almost still but alive: breathing in the chest (small −X/+X on
  `UpperTorso`, 1–2°), a slow weight shift between the feet, the head adjusting.
- `add_noise` on the chest, head and arms (1–3°, `frequency` 0.3–0.8) gives life without
  a visible pattern; over a whole looping clip it ends where it began.
- Nothing may freeze: check the motion plot for holds.
- Fighting idle: a bounce on the balls of the feet, the guard moving a little.

## Gestures: waves, points, nods

- **Wave:** raise the arm (0.4–0.5 s), a brief hold at the top, 2–3 swings of the forearm
  of about 50° each (0.3 s per swing), the hand trailing each swing by a few degrees, then
  lower. Lean the body slightly away and tilt the head toward the hand. Watch that the hand
  clears the head at the inward swing.
- **Point:** turn the head toward the target first, then the chest, then the arm. `aim`
  can keep the head on the target.
- Gestures read from the front; check them in a front strip.

## Jumps and landings

| Beat | Frames | Notes |
|---|---|---|
| Anticipation crouch | 6–10 | Hips down, knees bent, arms swing back |
| Push-off | 3–4 | Legs straighten as the hips rise; arms swing up |
| Rise and fall | depends on height | Ease out of the push-off and into the landing |
| Landing | 1–2 | Feet touch first |
| Absorb | 4–8 | Hips drop below standing height, knees bend, arms come down a frame or two after the hips, head one after that |
| Recover | 8–12 | Rise back to standing |

- The hips must rise **with** the legs straightening, or the feet push into the floor just
  before take-off. Add hip keys there if a strip or `track` shows it.
- **Check the absorb** with `track` on `LowerTorso`: lowest several frames after
  touchdown, not at it.
- Pin a landing at the **settled** pose (`at` set to the end of the range), not at
  touchdown, or the foot is held where it first touched. End the pin, and any `blend_out`,
  where the foot leaves the floor, or it slides.

## Hit reactions

- The part that's hit moves first, then the rest in a wave: for a hit to the face, the head
  snaps back, then the chest, then the hips. 1–2 frames of snap, 6–12 of recovery.
- Recover with an overshoot past the start, then settle. A stagger step sells a big hit.

## Falls and get-ups

- **Fall:** the knees give, the hips drop, the body rotates as a whole toward the floor; the
  arms reach to break it. Speed builds: it's slow at first and fast at the end.
- **On the floor:** `place_on_floor` with `mode: "touch"` and the parts that should rest
  (name the torso rather than the head for lying on the back: the head's box is deeper).
- **Get-up:** roll to the side or sit up, plant a hand and a foot, push up; each stage
  needs its own contacts pinned. Weight moves over the planted foot before the body rises.

## Turns and spins

- Lead with the head and eyes, then the chest, then the hips, then the feet.
- In a spin, the planted foot must stay put while the hips turn about it: pin it, and
  check with a strip from above (`top`) or two views.
