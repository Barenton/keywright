# Keywright

Keywright lets an AI agent make Roblox animations in Roblox Studio. You describe the motion you want, such as "a looping walk cycle", "a wave" or "getting hit and falling over". The agent then builds the animation on your rig, checks it, and saves it where Roblox's Animation Editor can open it.

It works with any AI app that supports the [Model Context Protocol](https://modelcontextprotocol.io) (MCP), such as Claude Code.

> **Status: early development.** Nothing has been released yet, and you build it from source. It has been used in Studio on Windows; see [What has been tested](#what-has-been-tested).

## Contents

- [How it works](#how-it-works)
- [What you need](#what-you-need)
- [Setup](#setup)
- [Your first animation](#your-first-animation)
- [Updating](#updating)
- [Troubleshooting](#troubleshooting)
- [What the agent can do](#what-the-agent-can-do)
- [Safety](#safety)
- [For contributors](#for-contributors)
- [What has been tested](#what-has-been-tested)
- [License](#license)

## How it works

Keywright has three parts:

```
AI app  ──>  adapter  ──>  broker  <──  Studio plugin
             (started by    (one per       (inside Roblox
             the AI app)    computer user)  Studio)
```

- **The Studio plugin** does all the animation work: it reads your rig, edits clips, plays them back to measure them, and saves them. Your animations never leave Studio.
- **The adapter** is what your AI app starts. It gives the agent a set of tools (listed [below](#tools)) and passes each request on.
- **The broker** is a small background program that connects adapters to Studio. The adapter starts it for you, and it only listens on your own computer (`127.0.0.1`).

The plugin and the broker trust each other through a one-time **pairing** step, which you do once per Studio install. After that they connect on their own.

## What you need

- **Roblox Studio**, on Windows. macOS has not been tried yet.
- **[Node.js](https://nodejs.org) 22 or later**, to build and run the adapter.
- **[Rokit](https://github.com/rojo-rbx/rokit)**, which installs the Roblox tools this project pins in `rokit.toml`, including [Rojo](https://rojo.space), which builds the plugin.
- **An AI app that supports MCP**, such as [Claude Code](https://claude.com/claude-code).

You can run the AI app and the adapter on Windows itself, or inside WSL while Studio runs on Windows. Both work.

## Setup

### 1. Get the code and build it

```sh
git clone https://github.com/Barenton/keywright.git
cd keywright
rokit install          # fetches Rojo and the other Roblox tools
npm install            # fetches the adapter's dependencies
npm run build          # builds the adapter into dist/
```

### 2. Install the plugin in Studio

```sh
npm run install:plugin
```

This builds the plugin and copies it into Studio's plugins folder as `Keywright.rbxm`. It finds the folder on Windows, from WSL, and on macOS. If you had saved the plugin from Studio before, as `Keywright.rbxmx`, it replaces that copy. It doesn't change anything else in the folder, but it tells you if it finds other copies of Keywright there, since Studio would load those too.

Studio picks up the new plugin on its own. If the **Keywright** button doesn't appear on the Plugins tab, restart Studio.

<details>
<summary>Installing by hand instead</summary>

Run `npm run build:plugin`, which writes `build/Keywright.rbxm`. In Studio, on the **Plugins** tab, click **Plugins Folder**. Studio opens its plugins folder, which is usually `%LOCALAPPDATA%\Roblox\Plugins`. Copy `Keywright.rbxm` into it. If you built it inside WSL, the file is at `\\wsl$\<your distro>\<path to keywright>\build\Keywright.rbxm`.

</details>

### 3. Add Keywright to your AI app

Your AI app starts the adapter with `node`, using the full path to `dist/src/cli.js` in your copy of the code.

**Claude Code:**

```sh
claude mcp add keywright -- node /full/path/to/keywright/dist/src/cli.js
```

**Other MCP apps:** most of them take a JSON entry like this one in their MCP settings:

```json
{
  "mcpServers": {
    "keywright": {
      "command": "node",
      "args": ["/full/path/to/keywright/dist/src/cli.js"]
    }
  }
}
```

Restart the AI app, or reconnect its MCP servers, so that it picks up the new server.

### 4. Turn on agent access and pair

Agent access is off by default, and it is turned on separately for each place.

1. Open a place in Studio. While you're learning, use a place you don't mind changing; see [Safety](#safety).
2. Click the **Keywright** button on the Plugins tab to show the panel.
3. Click **Turn on agent access**.
4. **The first time only:** the panel shows a line like `Pair once: run "keywright pair ABCD234XYZ" in a terminal.` Within 5 minutes, run that command from the `keywright` folder:

   ```sh
   node dist/src/cli.js pair ABCD234XYZ
   ```

   Use the code your panel shows, not this one. It works once.

The panel then says **Connected to the broker.** Studio remembers the pairing, and which places you turned agent access on for, so you only do this once.

## Your first animation

You need an **R15** rig in your place's Workspace: a character model with a `Humanoid` whose rig type is R15. Its joints can be `Motor6D`s or `AnimationConstraint`s. An R15 dummy from **Rig Builder** on Studio's **Avatar** tab works well. R6 rigs aren't supported yet.

**Close the Animation Editor while the agent works.** While it is open, Studio blocks the plugin from changing anything (see [Troubleshooting](#troubleshooting)).

Then ask your AI app, for example:

> Using Keywright, make a 1-second looping walk cycle for the rig in my place and save it as "Walk".

The agent will usually:

1. look at the place and your rig;
2. open a new **working copy**, a draft clip that is not saved anywhere yet;
3. build the motion in batches of edits;
4. look at poses and check the clip for problems, such as feet sliding or sinking into the floor;
5. save it as a new clip.

To see the result, select the rig, open the **Animation Editor**, and load the saved clip from its list. One Studio undo (**Ctrl+Z**) reverts any single batch of edits or a save, if you want to step back.

Some tips:

- **Be specific about what you want:** the length, whether it loops, the mood ("a tired walk", "a quick, snappy wave"), and anything that must stay still.
- **Ask for changes in plain words**, such as "the arms swing too much" or "make the landing heavier". The agent edits its working copy and saves the result under a new name.
- **Saving never overwrites a clip.** To replace an existing clip, the agent has to ask. The panel then shows **Replace the clip** and **Keep the clip as it is**, and nothing changes until you choose.

## Updating

From the `keywright` folder:

```sh
git pull
npm install
npm run install:plugin   # rebuilds the adapter and the plugin, and installs the plugin
```

Then reconnect Keywright in your AI app, for example with `/mcp` in Claude Code, so that it starts the new adapter. The old broker is replaced automatically the next time the adapter needs it.

The plugin and the adapter are released together and share one version number. The panel shows the plugin's version at the bottom, and `node dist/src/cli.js version` prints the adapter's. If they differ, the agent is told to ask you to update the older one. What changed in each version is in [CHANGELOG.md](CHANGELOG.md). Each release on the [Releases](https://github.com/Barenton/keywright/releases) page also has the built plugin attached, if you'd rather download it than build it.

## Troubleshooting

| What you see | What to do |
|---|---|
| Edits or saves fail while the Animation Editor is open | Close the Animation Editor. While it is open, Studio doesn't let plugins record undo steps, so Keywright refuses to make changes you couldn't undo. |
| The agent can't find a Studio session | Check that the Keywright panel says **Connected to the broker.** If you just reinstalled the plugin, reconnect the MCP server in your AI app. |
| The panel says the plugin or the adapter is older | Update the one it names, as in [Updating](#updating). The panel reconnects on its own once they match. |
| The panel says **Pairing is needed again** | Turn agent access off and on to get a new code, then run `node dist/src/cli.js pair <code>` again. |
| The pairing code stopped working | Codes last 5 minutes and work once. Turn agent access off and on for a fresh one. |
| The panel says **Another program is using the broker port**, or the agent gets `BROKER_PORT_CONFLICT` | Another program is using port 47318, which Keywright needs. Close that program, then turn agent access off and on. |
| You want to check the broker | Run `node dist/src/cli.js status`. |

Other commands are listed by `node dist/src/cli.js --help`. One worth knowing is `rotate`, which replaces the secret the broker uses. Every Studio window must pair again after it.

## What the agent can do

### Tools

These are the tools your AI app sees:

| Tool | What it does |
|---|---|
| `get_workspace` | Lists the connected Studio windows, with their rigs, saved clips and working copies. |
| `inspect_rig` | Describes a rig: its joints, how they connect, and their rest positions. |
| `open_animation` | Opens a working copy: blank, or a copy of an existing clip. The original is never changed. |
| `read_animation` | Reads a working copy: its length, settings, and the poses or keys of the joints asked for. |
| `edit_animation` | Applies a batch of edits. Either the whole batch applies or none of it does, and one Studio undo reverts it. |
| `validate_animation` | Checks a working copy: errors that would stop a save, and warnings such as feet sliding, scuffing or going through the floor. |
| `preview_animation` | Plays a working copy to an exact time on a hidden copy of the rig and reports where every joint is. It can also draw a simple picture of the pose. |
| `save_animation` | Saves a working copy as a new clip that the Animation Editor can load. |
| `discard_animation` | Throws a working copy away. |

The pose picture is drawn from the joint positions, with each body part as a box: the left side blue, the right side orange, and a mark on the front of the head. It shows the pose, not your rig's real look. Keywright doesn't take Studio screenshots; that code exists but is switched off.

### Two kinds of clip

Roblox stores animations in one of two forms, and Keywright edits both:

- **Keyframe clips** (`KeyframeSequence`): full poses at chosen moments, with fixed easing shapes between them. This is the Animation Editor's usual form.
- **Curve clips** (`CurveAnimation`): each joint has its own smooth curves, as in the Animation Editor's Curve Editor. Speed carries through a key instead of stopping at it, so curves are the better choice for motion that should flow, like walks and idles.

### Edits

`edit_animation` takes a list of operations. Besides setting poses and keys, there are operations that work with the body as a whole:

| For | Operations |
|---|---|
| Poses and keys | `set_pose`, `offset_pose`, `remove_pose`, `add_keyframe`, `move_keyframe`, `duplicate_keyframe`, `remove_keyframe`, `set_easing`, `set_key`, `remove_key`, `set_tangent`, `auto_tangents`, `clear_keys`, `copy_pose` |
| Timing | `shift_time` (which can also move a loop's starting point), `scale_time`, `reverse_time`, `reduce_keys` |
| Feet and hands | `pin` (keep a foot or hand planted, including heel and toe roll), `place_on_floor`, `clear_floor` |
| Body motion | `mirror` (copy one side onto the other, optionally half a cycle later), `match`, `aim` (turn the head or another joint toward a point), `overlap` (let a limb trail behind and settle), `add_offset`, `add_noise`, `smooth_motion` |
| Clip settings | `set_properties` (looping, priority), `set_marker`, `remove_marker`, `restore_source` |

In a looping clip, an edit whose time range touches the end also changes the start in the same way, so the loop stays seamless.

## Safety

- **Agent access is off until you turn it on**, separately for each place, and you can turn it off at any time from the panel.
- **Nothing is overwritten without asking.** Saving makes a new clip. Replacing an existing one needs you to click **Replace the clip** in the panel.
- **Every change can be undone.** Each batch of edits and each save is one Studio undo step.
- **Everything stays on your computer.** The broker listens only on `127.0.0.1` and turns away web pages and other machines. Every connection must prove it holds the pairing secret before anything is sent.
- **The agent can't run code.** No tool runs arbitrary Luau or touches your files.

Keywright doesn't protect you from harmful software that is already running on your computer under your user account.

While you're getting started, try Keywright in a copy of your place or a fresh baseplate, not a game you've published.

## For contributors

### Where the code is

| Folder | What is in it |
|---|---|
| `plugin/Main.server.luau` | The plugin's entry point: the panel, the agent access switch and pairing. |
| `plugin/src/Handlers.luau` | The requests a Studio session answers, one per tool. |
| `plugin/src/Core/` | Shared basics: errors, encoding, hashing, time limits. |
| `plugin/src/Network/` | The authenticated connection to the broker, and the per-place access switch. |
| `plugin/src/Rigs/` | Reading a rig's joints, and working out where its parts are for a pose. |
| `plugin/src/Storage/` | Working copies, saved clips, and requests to replace a clip. |
| `plugin/src/Editing/` | The edit operations for keyframe and curve clips, atomic batches, and undo. |
| `plugin/src/Inspection/` | Reading and checking clips. |
| `plugin/src/Preview/` | Playing a clip on a hidden copy of the rig, and the (disabled) screenshot path. |
| `plugin/fault/` | An extra module for the fault test build (see below). |
| `plugin/test/` | Offline Luau tests, in folders that match `plugin/src`. |
| `src/broker/` | The broker, its client, the handshake, the wire protocol and state files. |
| `src/mcp/` | The MCP adapter: the tools and their input schemas. |
| `src/render/` | Drawing pose pictures. |
| `test/` | TypeScript tests, in folders that match `src`. |
| `.github/workflows/` | CI, and the release workflow that runs when a version tag is pushed. |
| `scripts/` | The Luau test runner, the version and release-notes scripts, and the Studio measuring script. |

The plugin holds all of the animation logic. The TypeScript side only checks inputs, routes requests and draws pictures.

### Commands

```sh
npm test                  # build, then run the TypeScript tests
npm run test:luau         # run every plugin/test/**/*.test.luau with Lune
npm run format:check      # check Luau formatting with StyLua
npm run build:plugin      # build/Keywright.rbxm
npm run install:plugin    # build both, then install the plugin into Studio
npm run build:fault       # build/KeywrightFault.rbxm, the fault test build
npm run measure -- --place-id <id>   # measure against a connected Studio session
```

The Luau tests run outside Studio, against [Lune](https://lune-org.github.io/docs)'s Roblox datatypes, so they need no Studio window.

**`npm run measure`** drives the tools against a Studio session that is already connected, and writes its results to `build/measurements/`. It creates working copies, and saved clips named "Measure ...", in the open place. So it must be given that place's id, and it refuses any other. Use a place you can throw away.

**The fault test build** adds `plugin/fault/Fault.luau`, which makes an edit fail or stall on purpose. This lets you check in Studio that a failed batch leaves nothing behind. The fault is chosen by the working copy's name: "Fault fail", "Fault stall" or "Fault stall raw". Any other name behaves normally. Install it in place of the normal plugin, never alongside it, and only in a place you can throw away: "Fault stall raw" leaves that Studio window refusing undo steps until Studio restarts.

### Releasing

The plugin and the adapter share one version number, kept in `package.json`. `scripts/sync-version.mjs` copies it into `plugin/src/Version.luau`, and a test fails if the two differ. To release version 0.2.0:

1. In `CHANGELOG.md`, rename `## [Unreleased]` to `## [0.2.0] - <today's date>`, start a new empty `## [Unreleased]` above it, and update the links at the bottom. Commit that.
2. Run `npm version 0.2.0 -m "Release %s"`. This sets the version in `package.json` and the plugin, then commits and tags `v0.2.0`.
3. Run `git push --follow-tags`.

Pushing the tag starts the release workflow (`.github/workflows/release.yml`). It checks that the tag matches `package.json`, runs every test, builds the plugin, and publishes a GitHub release with `Keywright.rbxm` attached and that version's changelog section as its notes. Separately, the CI workflow runs the same tests on every push to `main` and every pull request.

## What has been tested

**Automated** (`npm test` and `npm run test:luau`):

- the handshake, pairing and rotation, and refusal of unauthenticated or forged messages;
- routing and timeouts, and a single broker when twenty adapters start at once;
- the MCP adapter end to end, against a stand-in plugin;
- every edit operation, the clip checks, saving and working copies, and pose pictures;
- that previews never move or change the real rig.

**Measured in Studio** on Windows, with the adapter in WSL, on rigs with `Motor6D` joints and rigs with `AnimationConstraint` joints:

- 10,000 round trips with none lost;
- sampled poses within 0.01° of the stored values;
- the same results from both joint types;
- clips that come back unchanged after a save and reopen.

**Checked in Studio by hand:**

- pairing, and reconnecting after a plugin reload;
- one undo reverting exactly one batch;
- pose pictures that match the Animation Editor;
- saved clips that load and play in the Animation Editor.

**Not tested yet:**

- macOS;
- two Studio windows at once;
- WSL with mirrored networking;
- MCP apps other than Claude Code showing the pose pictures;
- Studio screenshots, which are switched off.

## License

MIT. See [LICENSE](LICENSE).
