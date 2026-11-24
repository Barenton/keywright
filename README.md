# Motion Bridge

Motion Bridge lets AI agents author Roblox animations through the Model Context Protocol (MCP). A Roblox Studio plugin holds the animation engine; a small local relay connects MCP clients to it.

**Status: early development. Nothing is released, and the Studio plugin has not yet been run in Studio.** See [What is tested](#what-is-tested).

## How it fits together

```
MCP client ──stdio──> adapter ──loopback──> broker <──WebSocket── Studio plugin
(one adapter per client)        (one per OS user)           (opens the connection)
```

- **Plugin** (`plugin/`, Luau): rig inspection, working copies of `KeyframeSequence` clips, atomic edits with undo, and preview on a disposable clone of the rig. Screenshots of a preview go through Studio's permission-gated `StudioCaptureService` and are off by default: the installed plugin cannot enable them, and they run only in an armed disposable test fixture until their behaviour in Studio has been validated.
- **Adapter and broker** (`src/`, TypeScript): MCP tools, schema validation, session routing and authentication. They contain no animation logic.

Studio is the only place animation data lives. The broker holds routing state and can restart without losing anything.

## Security model

- The broker listens on `127.0.0.1` only and rejects requests that carry a web `Origin` or a non-loopback `Host`.
- Every connection runs a mutual challenge–response handshake before any request is sent or accepted. Adapters use a per-user secret file. The plugin pairs once with a one-time code and then uses a derived credential.
- A program that occupies the broker port without passing the handshake is reported as `BROKER_PORT_CONFLICT`. It receives one hello message and nothing else.
- No tool runs arbitrary Luau or touches the filesystem.

Malicious software already running as the same OS user is out of scope.

## Requirements

- Node.js 22 or later.
- [Aftman](https://github.com/LPGhatguy/aftman) for the Roblox tools pinned in `aftman.toml` (Rojo, Lune, StyLua).

## Commands

```sh
npm install
npm test                # build, then run the TypeScript tests
npm run test:luau       # headless tests for the Luau modules that only compute
npm run build:plugin    # build/MotionBridge.rbxm
```

### Studio fixture

`npm run prepare:fixture` writes a disposable Studio place and its instructions into `build/fixture/`. The place holds a baseplate and a unique fixture marker, and no scripts.

Preparation only writes those files. It does not start, stop or attach to Studio, install a plugin, open a network listener, or pair with a broker. Nothing in this project launches Studio.

The probe code in `plugin/probe/` refuses to act unless the open place is unpublished, in edit mode, and carries a fixture marker (`plugin/probe/FixtureGuard.luau`).

`npm run probe:wsl` checks, from WSL, that a Windows process can authenticate to a broker listening on loopback inside WSL. It does not involve Studio.

## What is tested

Tested by `npm test` and `npm run test:luau`:

- The handshake, pairing, credential reuse and rotation, and rejection of unauthenticated or forged messages.
- Request routing to the named session, timeouts, and structured errors.
- A single broker when twenty adapters start together, and detection of foreign listeners on the port.
- The MCP adapter over stdio against a stand-in plugin, including screenshots returned as image content.
- SHA-256, HMAC-SHA256, hex and base64 in Luau, against published test vectors and the TypeScript implementation.
- Fixture scoping: the guard that confines probe code to a disposable fixture, and the preparation script writing only inside `build/fixture/`.
- The picture of a pose: the plugin works out where each part is from the sampled joints, and the relay draws the parts as boxes. Both halves are deterministic and tested without Studio; that an `AnimationConstraint` places its part by the same rule as a `Motor6D` is taken from Roblox's documentation.
- The screenshot rules, against a model of `StudioCaptureService`: nothing is asked of Studio while the gate is closed, every wait has a deadline and a late result is not a success, only a complete PNG of the requested size is returned, the camera is never moved or changed, and an image taken while the approved scene or camera changed is dropped. The relay repeats the image checks on its side. None of this has run in Studio.
- Preview isolation, against a model of the animation engine: the preview samples a sanitized clone, never writes or steps the original rig, and removes what it created on success, failure and timeout. Whether Studio's engine matches that model is not yet verified.

Not yet tested, because each needs a person working in Studio:

- The plugin's transport, rig inspection on `Motor6D` and `AnimationConstraint` rigs, editing, undo, preview and screenshot capture.
- Interoperability with the Animation Editor, and plugin settings shared between Studio windows.
- Screenshots reaching the model in each MCP client.
- The plugin panel.

Also not yet tested: macOS, and WSL with mirrored networking.

## License

MIT. See [LICENSE](LICENSE).
