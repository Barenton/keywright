# Changelog

What changed in each release of Keywright. The plugin and the adapter are released together under one version number. Before 1.0, a new minor version (0.2, 0.3, ...) may change how things work; a new patch version (0.2.1) only fixes things.

## [Unreleased]

- **Guidance for agents:** every AI app is now sent instructions when it connects: plan the key poses, look at a pose strip after every revision as well as the motion plot, and don't take a clip that validates as finished. The tool reference shows them.
- **Keywright skill:** `skills/keywright/SKILL.md` goes further, from planning and blocking key poses to reviewing, contacts, loops and knowing when an animation is done. Claude Code users can copy it into `~/.claude/skills/`.

## [0.4.0] - 2026-11-26

- **On npm:** Keywright is published as the `keywright` package, so `npx -y keywright setup` installs it with nothing to download by hand. Run through npx, `setup` tells AI apps to start it with `npx -y keywright`, and the advice messages and the panel's pairing command give that form too. The README leads with it; the downloads from GitHub releases still work.
- **Fixed, pairing:** a refusal of the stored credential, which comes before the broker has proved itself, no longer erases it. That session pairs again, and the stored credential is replaced only when the new pairing succeeds, so a program posing as the broker can't wipe Studio's pairing.
- **Releases:** the release workflow can publish the npm package itself, through npm's trusted publishing, once it is switched on.
- **Public beta:** the README calls Keywright a public beta, from 0.3.0.

## [0.3.0] - 2026-11-26

**New**

- **Setup by an agent:** `node keywright.mjs setup` installs the plugin, prints how to add Keywright to Claude Code, Codex, Claude Desktop and other apps with the file's path filled in, and says what is left for the person. The README has a prompt to paste to an AI app that sets Keywright up this way. Inside WSL it also gives the `wsl.exe` entry, naming this distribution, that apps on Windows need.
- **Clearer refusal of an R6 rig:** it is told only that its rig type is not supported, not also each of the fifteen R15 joints it lacks.

**Fixed**

- **Access per place:** each place's agent access is now kept in a setting of its own. Before, every Studio window rewrote one shared list, so a window writing for one place could bring back access another window had just turned off. Access turned on before this version is still honoured.
- **Turning access off:** when Studio fails to save that access is off, the panel now says so, since access could otherwise come back on the next time the place opens. A setting that can't be read is no longer taken as saved.
- **Reconnecting:** a request that arrived on a new connection while one from the old connection was still finishing could wait forever. It now runs as soon as the old one is done.
- **Pairing:** two handshakes begun with one code could both get a credential, and a handshake left from a replaced code could finish or count against the new one. A registered code now pairs exactly one Studio window.
- **Rotate:** a broker still running on a port other than the one configured is now stopped too, so it can't go on accepting the old secret.
- **Broker start:** when a broker Keywright starts finds its port taken, the adapter reports the conflict, instead of waiting and then saying the broker didn't start.
- **Working copies:** a working copy a person moved out of Keywright's folder, for example among the Animation Editor's saved clips, is no longer listed or edited as a working copy.
- **Replacing a clip:** a renamed keyframe in the source now counts as a change, as game scripts see keyframe names. Working copies opened before this version treat their source as changed.
- **Setup's commands:** the Claude Code command adds Keywright for every project (`--scope user`), not just the folder it was run in. Paths in terminal commands are quoted for the shell, so characters such as `$` survive, and Windows paths keep single backslashes in PowerShell. The full path to Node is printed for apps that can't find `node`.
- **Versions:** pre-release versions are ordered as semantic versioning says (beta.2 before beta.10) when deciding whether to replace a running broker.
- **Building:** the bundler works when run from any folder.

**Hardening**

- `keywright.mjs` no longer looks for `ws`'s optional native modules, which Node would search for in folders above the release's.
- On macOS and Linux, Keywright's state folder and secret are closed to other users when found open, as after a restore, and state belonging to another user is refused.

**Documentation**

- A shorter README with a quick start, and new pages: a guide to making animations, troubleshooting, testing, and CONTRIBUTING.md for building from source and releasing.
- The docs say plainly that what the agent reads goes to your AI app, which may send it to its model provider, describe exactly what the adapter's image screening removes, and say when a pairing code's 5 minutes start.
- WSL with mirrored networking, and the beta demonstration in Claude Desktop and Codex, are recorded as tested, with new measurements taken with 0.2.0.

## [0.2.0] - 2026-11-26

- **Install without building:** each release now carries `keywright.mjs`, the adapter in one file that Node runs as it is, beside `Keywright.rbxm`. Download both into one folder, run `node keywright.mjs install-plugin`, and point your AI app at `node /path/to/keywright.mjs`. The panel's pairing command and the update advice give this form first. `THIRD_PARTY_LICENSES.txt` lists the licences of the packages built into it.
- **Pair through your AI app:** tell it "Pair Keywright with code …" and its adapter registers the code with the new `pair_studio` tool, so pairing needs no terminal. The panel shows the code and the terminal command in boxes that a click selects for copying.
- **Versions** read `v0.2.0` in the panel and the CLI, as the releases are titled.
- **Fixed:** under WSL's mirrored networking, after the broker stopped (for example after `rotate`), a new one was never started and Studio kept trying to connect; the adapter reported `BROKER_PORT_CONFLICT`. A port that only hangs now counts as free.
- **Tested:** WSL with mirrored networking, and the beta demonstration in Claude Desktop and Codex. The testing and limitations pages say so.

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

[Unreleased]: https://github.com/Barenton/keywright/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/Barenton/keywright/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Barenton/keywright/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Barenton/keywright/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/Barenton/keywright/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/Barenton/keywright/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Barenton/keywright/releases/tag/v0.1.0
