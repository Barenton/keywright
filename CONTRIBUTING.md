# Contributing

Thanks for your interest in Keywright. Bug reports and pull requests are welcome. Please report security problems privately, as described in [Security](docs/security.md#reporting-a-problem).

## Building from source

You need [Node.js](https://nodejs.org) 22 or later and [Rokit](https://github.com/rojo-rbx/rokit), which installs the Roblox tools pinned in `rokit.toml`, including [Rojo](https://rojo.space).

```sh
git clone https://github.com/Barenton/keywright.git
cd keywright
rokit install            # Rojo, Lune, StyLua and the other Roblox tools
npm install              # the adapter's dependencies
npm run install:plugin   # builds the adapter and the plugin, and installs the plugin
```

Then add Keywright to your AI app with `node /full/path/to/keywright/dist/src/cli.js`, and pair as the [README](README.md#3-turn-on-agent-access-and-pair) describes, using `node dist/src/cli.js` in place of `node keywright.mjs`. To update, run `git pull`, `npm install` and `npm run install:plugin`, then reconnect Keywright in your AI app.

## Where the code is

| Folder | What is in it |
|---|---|
| `plugin/Main.server.luau` | The plugin's entry point: the agent access switch, pairing, and what the panel says. |
| `plugin/src/Panel.luau` | The panel itself: how it is drawn and laid out at each size. |
| `plugin/src/Handlers.luau` | The requests a Studio session answers, one per tool. |
| `plugin/src/Core/` | Shared basics: errors, encoding, hashing, time limits. |
| `plugin/src/Network/` | The authenticated connection to the broker, the per-place access switch, and the plugin's settings. |
| `plugin/src/Rigs/` | Reading a rig's joints, and working out where its parts are for a pose. |
| `plugin/src/Storage/` | Working copies, saved clips, and requests to replace a clip. |
| `plugin/src/Editing/` | The edit operations for keyframe and curve clips, atomic batches, and undo. |
| `plugin/src/Inspection/` | Reading and checking clips. |
| `plugin/src/Preview/` | Playing a clip on a hidden copy of the rig, and the (disabled) screenshot path. |
| `plugin/fault/` | An extra module for the fault test build (see below). |
| `plugin/test/` | Offline Luau tests, in folders that match `plugin/src`. |
| `src/broker/` | The broker, its client, the handshake, the wire protocol and state files. |
| `src/mcp/` | The MCP adapter: the tools, their input schemas, and the tool reference writer. |
| `src/render/` | Drawing pose pictures. |
| `src/layout.ts` | Where Keywright's files are, whether it runs from `dist/` or as the single-file release. |
| `test/` | TypeScript tests, in folders that match `src`. |
| `docs/` | The documentation. `docs/tools.md` is written from the adapter's tools. |
| `scripts/` | The Luau test runner, the bundler, the version, release-notes and tool-reference scripts, and the Studio measuring script. |
| `.github/workflows/` | CI, and the release workflow that runs when a version tag is pushed. |

The plugin holds all of the animation logic. The TypeScript side checks inputs, routes requests and draws pictures.

## Commands

```sh
npm test                  # build, then run the TypeScript tests
npm run test:luau         # run every plugin/test/**/*.test.luau with Lune
npm run format:check      # check Luau formatting with StyLua
npm run build:plugin      # build/Keywright.rbxm
npm run install:plugin    # build both, then install the plugin into Studio
npm run build:release     # build/release/: the npm package (keywright.mjs, Keywright.rbxm, licences, package.json)
npm run build:fault       # build/KeywrightFault.rbxm, the fault test build
npm run docs:tools        # write docs/tools.md from the adapter's tools
npm run measure -- --place-id <id>   # measure against a connected Studio session
```

A test fails if `docs/tools.md` doesn't match the tools, so run `npm run docs:tools` after changing a tool's description or arguments.

### Measuring in Studio

`npm run measure` drives the tools against a Studio session that is already connected, and writes its results to `build/measurements/`. It creates working copies, which it discards, and one saved clip per rig named "Measure fixture …", which it keeps. So it must be given the place's id, and it refuses any other. Use a place you can throw away. See [Performance and accuracy](docs/performance.md) for the results.

### The fault test build

`npm run build:fault` adds `plugin/fault/Fault.luau`, which makes things go wrong on purpose, to check in Studio how Keywright copes. The fault is chosen by the working copy's name:

| Name | What happens |
|---|---|
| "Fault fail" | The batch fails after its first operation, so its undo recording is cancelled. |
| "Fault stall" | The batch never finishes; the plugin cancels its recording when it unloads. |
| "Fault stall raw" | As above, but nothing cancels the recording, to show what Studio does with one nobody finishes. |
| "Fault invalid" | A batch on a keyframe clip finishes with two keyframes at one time, so a save is refused. |

While the place has anything named "Fault settings" directly in Workspace, every write to the plugin's settings is dropped without an error, as Studio may do when several windows write at once.

Install it in place of the normal plugin, never beside it, and only for a place you can throw away: "Fault stall raw" leaves that Studio window refusing undo steps until Studio restarts.

## Releasing

The plugin and the adapter share one version number, kept in `package.json`. `scripts/sync-version.mjs` copies it into `plugin/src/Version.luau`, and a test fails if the two differ. Before 1.0, a new minor version (0.3, 0.4, …) may change how things work, and a patch version only fixes things. To release version 0.3.0:

1. In `CHANGELOG.md`, rename `## [Unreleased]` to `## [0.3.0] - <today's date>`, start a new empty `## [Unreleased]` above it, and update the links at the bottom. Commit that.
2. Run `npm version 0.3.0 -m "Release %s"`. This sets the version in `package.json` and the plugin, then commits and tags `v0.3.0`.
3. Run `git push --follow-tags`.

Pushing the tag starts the release workflow (`.github/workflows/release.yml`). It checks that the tag matches `package.json`, runs every test, builds the plugin and the single-file adapter, publishes the npm package, and publishes a GitHub release titled with the tag, with `keywright.mjs`, `Keywright.rbxm` and `THIRD_PARTY_LICENSES.txt` attached and that version's changelog section as its notes.

The workflow publishes to npm through npm's trusted publishing, with no token stored: the package's settings on npmjs.com name this repository and `release.yml` as its trusted publisher, and the repository variable `NPM_PUBLISH` is set to `true`. Without that variable, the npm step is skipped, and `npm run build:release` then `npm publish build/release` publishes by hand. The CI workflow runs the same tests on every push to `main` and every pull request.
