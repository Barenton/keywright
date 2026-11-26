# Guide

How to get good animations out of Keywright, and what the agent can do. To install it, see the [README](../README.md#quick-start).

## Your rig

Keywright works with **R15** rigs: a character model under Workspace with a `Humanoid` whose rig type is R15, and the 15 standard R15 joints. The joints can be `Motor6D`s or `AnimationConstraint`s. An R15 dummy from **Rig Builder** on Studio's **Avatar** tab works well. R6 rigs aren't supported.

## Making an animation

Ask your AI app for what you want, for example:

> Using Keywright, make a 1-second looping walk cycle for the rig in my place and save it as "Walk".

The agent will usually:

1. look at the place and your rig;
2. open a **working copy**, a draft clip that isn't saved anywhere yet;
3. build the motion in batches of edits;
4. look at pictures of poses, and check the clip for problems such as feet sliding or sinking into the floor;
5. save it as a new clip.

To see the result, select the rig, open the **Animation Editor**, and load the saved clip. Close the Animation Editor while the agent works: while it plays a clip, Studio can refuse the agent's changes. One Studio undo (**Ctrl+Z**) reverts any single batch of edits or a save.

### Tips

- **Be specific:** the length, whether it loops, the mood ("a tired walk", "a quick, snappy wave"), and anything that must stay still.
- **Ask for changes in plain words,** such as "the arms swing too much" or "make the landing heavier". The agent edits its working copy and saves the result under a new name.
- **Replacing a clip needs you.** Saving never overwrites a clip. When the agent asks to replace one, the panel shows **Replace the clip** and **Keep the clip as it is**, and nothing changes until you choose.

## What the agent sees

The agent can't watch the animation play. It samples the clip at exact times and gets back where every joint and part is, and it can ask for a **pose picture**: the rig drawn from those positions, each part as a box, the left side blue, the right side orange, and a mark on the front of the head. A picture can be a filmstrip of several moments, or compare the clip with another one. It shows the pose, not your rig's real look, and it isn't a Studio screenshot.

## Two kinds of clip

Roblox stores animations in one of two forms, and Keywright edits both:

- **Keyframe clips** (`KeyframeSequence`): full poses at chosen moments, with fixed easing shapes between them. This is the Animation Editor's usual form.
- **Curve clips** (`CurveAnimation`): each joint has its own smooth curves, as in the Animation Editor's Curve Editor. Speed carries through a key instead of stopping at it, so curves suit motion that should flow, like walks and idles. Studio plays them at 30 frames a second, so keys belong on whole frames.

A keyframe clip can be converted to curves, but not the other way round.

## Edits

`edit_animation` takes a batch of operations, applied in order. If any one can't be done, nothing changes. Besides setting poses and keys, there are operations that work with the body as a whole:

| For | Operations |
|---|---|
| Poses and keys | `set_pose`, `offset_pose`, `remove_pose`, `set_easing`, `add_keyframe`, `move_keyframe`, `duplicate_keyframe`, `remove_keyframe`, `set_key`, `remove_key`, `set_tangent`, `auto_tangents`, `clear_keys`, `copy_pose` |
| Timing | `shift_time` (which can also move a loop's starting point), `scale_time`, `reverse_time`, `reduce_keys` |
| Feet and hands | `pin` (keep a foot or hand planted, with heel and toe roll), `place_on_floor`, `clear_floor` |
| Body motion | `mirror` (copy one side onto the other, optionally half a cycle later), `aim` (turn the head or another joint toward a point), `overlap` (let a limb trail behind and settle), `add_offset`, `add_noise`, `smooth_motion` |
| Clip settings | `set_properties` (name, looping, priority), `set_marker`, `remove_marker`, `restore_source` |

In a looping clip, an edit whose time range touches the end also changes the start, so the loop stays seamless. Each operation, with every argument, is in the [tool reference](tools.md#operations).

## Checks

`validate_animation` reports two kinds of finding. **Errors** mean the clip can't be saved, such as a pose for a joint the rig doesn't have. **Warnings** are measurements to look at, and never stop a save: a loop that doesn't close, a joint turning faster than a limit, a foot sliding or sinking into the floor. They are measurements, not taste: a fast punch can be meant. Every code is explained in [Errors and findings](errors.md).

## Updating

```sh
npx -y keywright@latest update
```

It installs the newest plugin and tells you what's left: reconnect Keywright in your AI app, for example with `/mcp` in Claude Code, so that it starts the new adapter. The old broker is replaced the next time it's needed. With the downloaded files instead, download `keywright.mjs` and `Keywright.rbxm` from the [latest release](https://github.com/Barenton/keywright/releases/latest) over the old ones, and run `node keywright.mjs update` in their folder.

You don't have to watch for releases: once a day Keywright checks whether a newer one is out, and your AI app mentions it. To turn that check off, set `KEYWRIGHT_NO_UPDATE_CHECK=1` in the app's settings for Keywright; [Security](security.md) says what it sends.

The plugin and the adapter share one version number. The panel shows the plugin's at the bottom, and `npx -y keywright@latest version` prints the adapter's. If they differ, the agent is told to ask you to update the older one.
