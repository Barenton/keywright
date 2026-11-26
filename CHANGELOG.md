# Changelog

What changed in each release of Keywright. The plugin and the adapter are released together under one version number. Before 1.0, a new minor version (0.2, 0.3, ...) may change how things work; a new patch version (0.2.1) only fixes things.

## [Unreleased]

- **Tested:** WSL with mirrored networking, and the beta demonstration in Claude Desktop and Codex. The README and the limitations page say so.

## [0.1.2] - 2026-11-26

- **Documentation:** a tool reference written from the tools themselves, and pages on errors and findings, security, limitations, and measured performance, in `docs/`.
- **Tool descriptions:** every argument and operation field now says what it is for.
- **Fixed:** a working copy whose rig was deleted stayed listed until the plugin reloaded. It is now counted with the working copies whose rig is gone, and listed again if the rig comes back.
- **Fixed:** the advice to close the Animation Editor before the agent works. Checked in Studio on 2026-11-26: edits, previews and saves all work with the editor open, with a clip loaded in it and with it playing, and during Play and Run. When Studio does refuse an undo step, the message now says to finish what is in progress in Studio.

## [0.1.1] - 2026-11-26

- **Fixed:** clicking the agent access switch quickly could leave access remembered as on while the switch showed it off, so that access turned itself on the next time the place opened. The last click is now the one remembered.
- **Settings:** checked in Studio with two windows open on two places. Access turned on in one is kept when it is turned on in the other, also at the same moment, and a setting that Studio fails to save is reported on the panel.

## [0.1.0] - 2026-11-25

The first numbered release.

- **Studio plugin:** reads R15 rigs jointed with `Motor6D` or `AnimationConstraint`, and edits keyframe clips (`KeyframeSequence`) and curve clips (`CurveAnimation`) in working copies. Each batch of edits is atomic and is one Studio undo step. It saves clips where the Animation Editor keeps them, never overwriting one without a person approving it in the panel.
- **Edits:** poses and keys, tangents, timing, mirroring, and whole-body operations: planting feet and hands with heel and toe roll, keeping feet on and off the floor, aiming, overlap, offsets and noise. In a looping clip, an edit that reaches the end changes the start in the same way.
- **Checks:** structural errors that would stop a save, and warnings for loops that don't close, joints moving too fast, and feet that slide, scuff or go through the floor.
- **Previews:** a clip is played to an exact time on a hidden copy of the rig, with a simple picture of the pose.
- **Adapter and broker:** MCP tools for any MCP app, connected to Studio over an authenticated loopback link that is paired once.
- **Setup:** `npm run install:plugin` installs the plugin into Studio. The panel and `node dist/src/cli.js version` show the version, and the agent is told when the plugin and the adapter don't match.
- **Panel:** fits whatever size it is docked or floated at, follows Studio's theme, and shows the pairing command ready to copy.

[Unreleased]: https://github.com/Barenton/keywright/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/Barenton/keywright/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/Barenton/keywright/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Barenton/keywright/releases/tag/v0.1.0
