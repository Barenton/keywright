# Changelog

What changed in each release of Keywright. The plugin and the adapter are released together under one version number. Before 1.0, a new minor version (0.2, 0.3, ...) may change how things work; a new patch version (0.2.1) only fixes things. New features always come in a new minor version, even when nothing else changes. A change that needs something done after upgrading is marked **Breaking**.

## [Unreleased]

**New**

- **`update`:** `npx -y keywright@latest update` installs the newest plugin, checks that it is the newest release, and says what is left: reconnecting Keywright in the AI app. Run from a downloaded file that is older than the newest release, it says where to get that first. Update advice in the panel and in `update_needed` now gives this command.
- **Copy a pose from another clip:** `copy_pose` takes `from_clip`, naming another clip of the same rig as `compare_with` does. A revised guard in a ready clip can be carried into every attack's start and recovery, copying only the joints and channels named, so each attack keeps its feet, timing and markers. A keyframe clip can be the source; it is only read.
- **`nudge`:** move a hand or foot off its own path by an offset for a few frames, easing in and out, the limb solved to follow: lift a kicking foot at the chamber, carry a punch higher. Unlike `pin`, which holds a point and so drags a fast limb back toward it while easing out, the part keeps travelling along its own motion. The skill has the recipe for fixing what an onion skin or a measurement shows.
- **Told when a newer release is out:** once a day, in the background, the adapter asks npm's registry for the latest version of Keywright. When it is newer, `get_workspace` carries `update_available` with the steps, and agents are told to mention it once. The request carries nothing about you or your work; `KEYWRIGHT_NO_UPDATE_CHECK=1` turns it off.

**Fixed**

- **`pin` and `nudge` near full stretch:** with `soft`, a limb near full stretch no longer jumps on the first frame of a blend; the softening now eases in with it.
- **A point too near to reach is reported:** a hand or foot asked to come closer than its limb can fold is now counted in `frames_out_of_reach`, not reported as softened.
- **No clip made longer by an edit:** the key `pin`, `nudge` and other per-frame operations add after their range to keep the motion beyond it no longer lands past the clip's end.
- **Ranges across a loop's end need a loop that closes:** where a channel ends on another value than it starts (0 to 360 degrees, the same pose in other numbers), joining its end to its start could move a limb by studs, so such a range is now refused, with the hint to close the loop first.
- **A curve read at a key just after a step:** operations that read a curve (`copy_pose`, `pin`, `aim` and others) took the value before a key, at that key's own time, when the stretch before it was Constant. They now take the key's own value, as Studio plays it.

## [0.6.0] - 2026-11-26

**New**

- **Measurements:** `preview_animation` takes `measure`: one part from another, or from the root, along the rig's forward, up or right, or as a distance, at every time sampled. It returns each value with the least and greatest and when they happen, so a punch's reach past the head, how low the hips sink after a landing and when, or a planted foot's drift is one call. The parts measured are tracked automatically.
- **Onion skin:** `preview_animation` with `times`, `render` and `onion: true` draws the moments over each other, the last solid and earlier ones fainter. Each tracked part's arm or leg is drawn stronger, with its path through the frames and a numbered dot at each, which shows where a limb turns round and whether it moves in an arc.
- **Labelled strips:** each column of a pose strip, and of a comparison, now shows its time.
- **Comparing retimed moves:** `preview_animation` takes `compare_times` with `compare_with`: the other clip's own time for each of `times`, so a before-and-after strip pairs impact with impact even when the move now lands on a different frame. The compared clip's row is labelled with its times, and each comparison reports `other_time`.
- **Out-of-date plugin or adapter, flagged everywhere:** while a Studio window's plugin and the adapter are different versions, every result for that window, errors included, starts with `update_needed`, not just `get_workspace`. It says which side is older, that newer options are ignored until they match, and how to update. Agents are told to pass it on to the person straight away.
- **Pictures say how they were drawn:** every picture's `render` reports its `style`, so an agent can tell the style it asked for was used. An adapter too old to know `style` leaves it out.

**Fixed**

Most of these were found by independent reviews of this release and earlier ones.

- **Setup runs the published package, not a project's own.** Apps are now told to start Keywright with `npx -y keywright@latest`: with a bare `npx -y keywright`, a project with its own `keywright` program (a package of that name, or one in `node_modules/.bin`) ran that instead whenever the app started in it. If your app was set up with `npx -y keywright`, run `npx -y keywright@latest setup` again, or add `@latest` to its entry yourself.
- **A place's access stays off when its setting can't be read.** Before, an unreadable setting of its own let the older shared list turn access back on in a place that had been turned off.
- **Requests still waiting when the connection drops are dropped with it.** Before, a request queued behind a running one could still run after the connection was lost, with nowhere to send the answer: the agent, told the call had failed, could send it again and the change be made twice.
- **Rotating the secret stops every broker using it,** on any port: each broker now stops as soon as its secret file changes. Before, a second broker started with another `KEYWRIGHT_PORT` could keep accepting the old secret.
- **Setup's entry for Windows apps using Keywright in WSL works with node from nvm:** it puts node's folder on the `PATH`, which `wsl.exe --exec` doesn't set up.
- **Loops just off a whole frame:** in a loop whose end was typed a little off a frame (0.667 for 20/30 of a second), `pin`, `aim` and other ranges across the end put the keys that came round it just off a frame, which gave `KEY_OFF_FRAME` warnings. The loop is now cut and joined at its whole number of frames.
- **Replacing a clip notices attributes changed in it since,** as it notices other changes: attributes now count in the source's fingerprint and are watched. Fingerprints written by earlier versions are still checked the way they were made.
- **A working copy moved to another rig's shelf** is no longer edited with the first rig's joints for the rest of the session; it is found again on its new shelf after a reload.
- **State files are created afresh,** so a link left at a temporary file's path, in a folder copied in, is never written through.
- **After pairing, a later refusal needs one off-and-on, not two.**
- **Slim pictures keep a limb's longest side,** on a custom rig whose arms or legs run along another direction.
- **Releases:** a release whose npm step failed can be rerun: the GitHub release already made gets this run's files. A prerelease goes to npm with the `next` tag, which npm requires.
- **Security page:** what the pairing command line exposes on a shared computer, why wrong pairing proofs count from any connection, and two limits: changing the port, and `KEYWRIGHT_HOME` on Windows.

## [0.5.0] - 2026-11-26

- **Slim pose pictures:** `preview_animation` takes `style: "slim"`, which draws the arms and legs thin along their length, so limb angles, elbow and knee bends and arm swings read; on a blocky rig, boxes hide them. The default boxes are unchanged.
- **The Animation Editor can block changes after all:** while it played a clip, Studio refused every Keywright change until it was closed. The docs and the plugin's message now say to close it.
- **Keywright skill:** judge the upper and lower body separately, and compare with an animation the person likes by reading its keys. Runs swing the arms well back with the elbows held bent, and land the feet nearly in line.
- **Keywright skill:** each problem found in an agent's run cycle is now a check, not just advice: the hips must keep sinking 2–3 frames after every landing, no limb may stop partway through a swing, a stance rolls onto the toe for the push-off, frame times are written exactly, and `reduce_keys` runs before saving.
- **Guidance for agents:** every AI app is now sent instructions when it connects: plan the key poses, look at a pose strip after every revision as well as the motion plot, and don't take a clip that validates as finished. The tool reference shows them.
- **Keywright skill:** `skills/keywright/` teaches an agent an animator's workflow on Keywright's tools: planning and blocking key poses, reviewing every revision, body mechanics, contacts and loops, and when an animation is done. Its references cover which way R15 joints turn, timing and method for common moves, and what to change for each kind of problem. Claude Code users can copy the folder into `~/.claude/skills/`.

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

[Unreleased]: https://github.com/Barenton/keywright/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/Barenton/keywright/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/Barenton/keywright/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/Barenton/keywright/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Barenton/keywright/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Barenton/keywright/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/Barenton/keywright/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/Barenton/keywright/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Barenton/keywright/releases/tag/v0.1.0
