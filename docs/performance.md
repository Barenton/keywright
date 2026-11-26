# Performance and accuracy

Measured in Studio with `npm run measure`, which drives the ordinary tools against a connected Studio window, the same way an AI app's adapter does. Times are taken at the adapter's end, so they include the trip through the broker to Studio and back.

## The run

| | |
|---|---|
| Date | 2026-11-24 |
| Keywright | A build from before version numbers, with the same tools as 0.1.0 |
| Studio | Roblox Studio on Windows 11 |
| Adapter and broker | Node.js in WSL 2, with WSL's default (NAT) networking |
| Computer | AMD Ryzen 7 9800X3D, 32 GB of memory |
| Rigs | Two R15 rigs, one jointed with `Motor6D` and one with `AnimationConstraint` |

Two reference clips are built by the script itself, so every run measures the same thing:

- **Ref-S:** 3 seconds, 31 keyframes, 15 joints, 465 poses.
- **Ref-L:** 30 seconds, 301 keyframes, 15 joints, 4,515 poses.

## Speed

The 95th percentile of 30 calls, against the targets Keywright was designed to.

| Operation | Target | Measured |
|---|---|---|
| `edit_animation`, a batch of 50 operations on Ref-S | 1 s | 7 ms |
| `edit_animation`, one joint at one keyframe on Ref-L | 1 s | 17 ms |
| `read_animation` summary of Ref-L | 500 ms and 16 KiB | 6 ms and 1,760 bytes |
| `inspect_rig` summary | 300 ms | 6 ms |
| `preview_animation` of Ref-L at one time, with a pose picture | 1 s | 29 ms |
| `validate_animation` on Ref-L | 1 s | 18 ms |
| `preview_animation` filmstrip of Ref-S, eight frames compared with another clip | 3 s | 189 ms |
| Reconnecting after the broker restarts | the next call works within 5 s | 0.64 to 1.72 s |

Reconnecting was timed by hand, from restarting the broker to the plugin's next successful call.

## Reliability

| Check | Result |
|---|---|
| 10,000 requests and answers, 25 at a time | none lost or wrong; 95th percentile 51 ms a round trip |
| 200 edits that depend on each other, sent at once | all applied, in the order sent |
| A 1.36 MB answer from Studio (10,710 poses) | arrived whole, every pose as written |
| A request carrying 1 MiB beside an edit | read, and the edit applied |
| A stale edit from a second client | refused |
| Two Studio windows on two places | both connected, each call reached only the window it named, and turning access on in both, even at the same moment, was remembered for both |

## Accuracy

| Check | Measured | Limit |
|---|---|---|
| Rotation sampled at keyframe times, against the stored poses, both joint types | 0.006° at worst | 0.01° |
| Position sampled at keyframe times | 0 studs | 0.001 studs |
| 100 samples at the same time | all identical | identical |
| The same clip on the two joint types, joint rotations at 11 times | 0.003° at worst | 0.01° |
| The same, joint positions | 0 studs | 0.001 studs |
| Where Studio puts each of the 15 parts, against where the joint transforms say, at 11 times, on each rig | 0.000002 studs, 0° | 0.001 studs, 0.01° |
| A clip saved and opened again | its fingerprint unchanged | unchanged |

The fingerprint is `read_animation`'s `content_hash`, a hash of everything that affects how a clip plays.

## Not measured

- **Screenshots**, which are switched off. The target for taking one is 3 seconds.
- **What 100 previews leave behind:** that Studio's instance and connection counts come back to where they started. No tool reports them. Each preview is checked to remove its copy of the rig, but the totals haven't been counted.
- **An idle broker's CPU use.** The broker exits by itself 10 minutes after its last adapter disconnects.
- **macOS.**

## Measuring it yourself

The script changes the place it runs in, so use a place you can throw away:

1. Open the place in Studio, with a standard R15 rig under Workspace, and turn agent access on.
2. Run `npm run measure -- --place-id <id>`, with that place's id. The script refuses any other place.

The script makes working copies and discards them at the end. It also saves one clip for each rig, named "Measure fixture ...", and uses it again on later runs. It writes its results to `build/measurements/`. The round-trip test makes 10,000 trips; `--rounds` sets another number, from 10 to 100,000.
