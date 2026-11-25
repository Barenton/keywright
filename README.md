# Keywright

Keywright lets AI agents author Roblox animations through the Model Context Protocol (MCP). A Roblox Studio plugin holds the animation engine; a small local relay connects MCP clients to it.

**Status: early development. Nothing is released.** The plugin has been run in Studio on Windows by hand and by a measuring script; see [What is tested](#what-is-tested).

## How it fits together

```
MCP client ──stdio──> adapter ──loopback──> broker <──WebSocket── Studio plugin
(one adapter per client)        (one per OS user)           (opens the connection)
```

- **Plugin** (`plugin/`, Luau): rig inspection, working copies of clips made of keyframes (`KeyframeSequence`) or curves (`CurveAnimation`), atomic edits with undo, sampling a clip on a disposable copy of the rig, and saving clips where Roblox's Animation Editor keeps them.
- **Adapter and broker** (`src/`, TypeScript): MCP tools, schema validation, session routing and authentication. The adapter also draws the picture of a pose from the joint positions the plugin samples. They contain no animation logic.

Studio is the only place animation data lives. The broker holds routing state and can restart without losing anything.

### Where the code is

| Folder | What is in it |
|---|---|
| `plugin/Main.server.luau` | The plugin's entry point: the agent access switch, pairing, and connection status. |
| `plugin/src/Handlers.luau` | The methods a Studio session answers, one per tool. |
| `plugin/src/Core/` | Shared basics: structured errors, encoding, hashing, time limits, the engine's libraries. |
| `plugin/src/Network/` | The authenticated connection to the broker, and the per-place access switch. |
| `plugin/src/Rigs/` | Reading a rig's joints, and working out where its parts are for a pose. |
| `plugin/src/Storage/` | Working copies, saved clips, and proposals to replace a clip. |
| `plugin/src/Editing/` | The edits for keyframe clips and for curve clips, atomic batches, and undo recordings. |
| `plugin/src/Inspection/` | Reading a clip, checking it, and fingerprinting it. |
| `plugin/src/Preview/` | Sampling a clip on a disposable copy of the rig, and the gated screenshot path. |
| `plugin/fault/` | The extra module for the test build described below. |
| `plugin/test/` | Offline Luau suites, in folders matching `plugin/src`. `npm run test:luau` runs every `*.test.luau`. |
| `src/broker/` | The broker, the client that connects to it, its handshake, wire protocol and state files. |
| `src/mcp/` | The MCP adapter: the tools and their schemas. |
| `src/render/` | Pictures of poses and motion, and screenshot results. |
| `test/` | TypeScript tests, in folders matching `src`, plus checks on the scripts in `scripts/`. |

## Tools

| Tool | What it does |
|---|---|
| `get_workspace` | Lists connected Studio sessions with their rigs, saved clips and working copies. |
| `inspect_rig` | Describes a rig: joints, joint class and rest transforms. |
| `open_animation` | Makes a working copy: blank, from the selected clip, or from one of the rig's saved clips. |
| `read_animation` | Reads a working copy, with pose values only for the joints asked for. |
| `edit_animation` | Applies a batch of edits atomically. One Studio undo reverts the batch. |
| `preview_animation` | Samples a working copy at a time. With `render: true`, also returns a picture of the pose. |
| `save_animation` | Saves a copy as a new clip that the Animation Editor can load. Never replaces a clip. |
| `discard_animation` | Removes a working copy. |

The picture of a pose is drawn by the adapter from the sampled joint positions: each part is a box, the rig's left side is blue and its right side orange, and the head carries a mark on its front. It shows the pose, not the rig's appearance, and involves no screenshot.

Viewport screenshots through Studio's `StudioCaptureService` exist in the code but are switched off. The installed plugin cannot enable them.

## Security model

- The broker listens on `127.0.0.1` only and rejects requests that carry a web `Origin` or a non-loopback `Host`.
- Every connection runs a mutual challenge–response handshake before any request is sent or accepted. Adapters use a per-user secret file. The plugin pairs once with a one-time code and then uses a derived credential. `keywright rotate` replaces the secret, after which every Studio window must pair again.
- A program that occupies the broker port without passing the handshake is reported as `BROKER_PORT_CONFLICT`. It receives one hello message and nothing else.
- No tool runs arbitrary Luau or touches the filesystem.

Malicious software already running as the same OS user is out of scope.

## Requirements

- Node.js 22 or later.
- [Rokit](https://github.com/rojo-rbx/rokit) for the Roblox tools pinned in `rokit.toml` (Rojo, Lune, StyLua, selene, luau-lsp). Run `rokit install` in the project folder.

## Commands

```sh
npm install
npm test                # build, then run the TypeScript tests
npm run test:luau       # headless tests for the Luau modules that only compute
npm run build:plugin    # build/Keywright.rbxm
npm run build:fault     # build/KeywrightFault.rbxm, a test build (see below)
npm run measure -- --place-id <id>   # measure against a connected Studio session
```

`npm run measure` drives the tools above against a Studio session that a person has already connected, and writes its results to `build/measurements/`. It reaches Studio only through the local broker. It makes working copies and saved clips named "Measure ..." in the open place, so it must be given that place's id and refuses any other. Use a place you can throw away.

### Test build

`npm run build:fault` builds the plugin with one extra module, `plugin/fault/Fault.luau`, which makes an edit fail or stop after its first operation. It exists to check in Studio what happens to a half-finished batch: that a failed batch leaves nothing behind, and that an undo recording left open is cancelled when the plugin unloads. Which fault happens is chosen by the name of the working copy being edited ("Fault fail", "Fault stall", "Fault stall raw"); other working copies behave as usual. A session from this build reports its version with `+fault`, and the panel says it is a test build. Install it in place of the normal plugin, never beside it, and only in a place you can throw away: "Fault stall raw" leaves Studio refusing undo recordings in that window until Studio is restarted.

## What is tested

Tested by `npm test` and `npm run test:luau`:

- The handshake, pairing, credential reuse and rotation, and rejection of unauthenticated or forged messages.
- Request routing to the named session, timeouts, and structured errors.
- A single broker when twenty adapters start together, and detection of foreign listeners on the port.
- The MCP adapter over stdio against a stand-in plugin, including cancellation and what may be returned as an image.
- SHA-256, HMAC-SHA256, hex and base64 in Luau, against published test vectors and the TypeScript implementation.
- The picture of a pose: the plugin works out where each part is from the sampled joints, and the adapter draws the parts as boxes. The tests decode the picture and check what is where.
- Saving where the Animation Editor keeps clips, working copies that survive a plugin reload, remembered agent access, and the clip fingerprint.
- Preview isolation, against a model of the animation engine: the preview samples a sanitized copy, never writes or steps the original rig, and removes what it created on success, failure and timeout.
- The screenshot rules, against models of `StudioCaptureService` and of Studio: nothing is asked of Studio while the gate is closed, every wait has a deadline, only a complete PNG of the requested size is returned, and the camera is never moved.

Measured in Studio on Windows, with the adapter in WSL, by `npm run measure` on one `Motor6D` rig and one `AnimationConstraint` rig:

- 10,000 request and response round trips with none lost, and 200 dependent edits sent at once applied in order.
- Sampled values within 0.01 degrees of the stored poses at keyframe times, and identical across 100 repeated samples.
- The same clip giving the same joint transforms on both joint classes.
- A round trip through saving and opening that leaves a clip's fingerprint unchanged.
- The whole walk-through on each rig: inspect, open, edit, preview, picture, a stale write from a second client refused, and the source restored.

Checked in Studio by hand:

- Pairing, reconnecting after a plugin reload, and one Studio undo reverting exactly one batch or one save.
- A pose picture matching what the Animation Editor shows for the same clip.
- Saved clips loading and playing in the Animation Editor, a clip the editor re-saved being identical to the original, and a clip made in the editor reading back correctly.

Found along the way: while the Animation Editor is open, Studio does not let the plugin start an undo step, so tools that change anything fail until it is closed.

Not yet tested:

- Screenshots. The capture path has not run in Studio and is switched off.
- Two Studio windows at once, and a broker restart under load.
- Pictures reaching the model in MCP clients other than Claude Code.
- The plugin panel beyond turning access on and off.

Also not yet tested: macOS, and WSL with mirrored networking.

## License

MIT. See [LICENSE](LICENSE).
