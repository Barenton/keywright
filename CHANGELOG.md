# Changelog

What changed in each release of Keywright. The plugin and the adapter are released together under one version number. Before 1.0, a new minor version (0.2, 0.3, ...) may change how things work; a new patch version (0.2.1) only fixes things.

## [Unreleased]

## [0.1.0] - 2026-11-25

The first numbered release.

- **Studio plugin:** reads R15 rigs jointed with `Motor6D` or `AnimationConstraint`, and edits keyframe clips (`KeyframeSequence`) and curve clips (`CurveAnimation`) in working copies. Each batch of edits is atomic and is one Studio undo step. It saves clips where the Animation Editor keeps them, never overwriting one without a person approving it in the panel.
- **Edits:** poses and keys, tangents, timing, mirroring, and whole-body operations: planting feet and hands with heel and toe roll, keeping feet on and off the floor, aiming, overlap, offsets and noise. In a looping clip, an edit that reaches the end changes the start in the same way.
- **Checks:** structural errors that would stop a save, and warnings for loops that don't close, joints moving too fast, and feet that slide, scuff or go through the floor.
- **Previews:** a clip is played to an exact time on a hidden copy of the rig, with a simple picture of the pose.
- **Adapter and broker:** MCP tools for any MCP app, connected to Studio over an authenticated loopback link that is paired once.
- **Setup:** `npm run install:plugin` installs the plugin into Studio. The panel and `node dist/src/cli.js version` show the version, and the agent is told when the plugin and the adapter don't match.
- **Panel:** fits whatever size it is docked or floated at, follows Studio's theme, and shows the pairing command ready to copy.

[Unreleased]: https://github.com/Barenton/keywright/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Barenton/keywright/releases/tag/v0.1.0
