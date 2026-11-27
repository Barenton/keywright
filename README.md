# Keywright

**Let an AI agent animate your Roblox rigs.**

[![CI](https://github.com/Barenton/keywright/actions/workflows/ci.yml/badge.svg)](https://github.com/Barenton/keywright/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Barenton/keywright)](https://github.com/Barenton/keywright/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Keywright connects Roblox Studio to AI apps that support the [Model Context Protocol](https://modelcontextprotocol.io) (MCP), such as Claude Code, Claude Desktop and Codex. Describe the motion you want, such as "a looping walk cycle", "a wave" or "getting hit and falling over", and the agent builds it on your rig, checks it, and saves it where Roblox's Animation Editor can open it.

- **Works on your rigs.** Standard R15 characters, jointed with `Motor6D` or `AnimationConstraint`.
- **Edits real clips.** Keyframe clips and curve clips, the two forms the Animation Editor uses.
- **Body-aware tools.** Planting feet and hands, mirroring, aiming, overlap, and keeping feet on the floor.
- **Checks its work.** Finds loops that don't close, joints that move too fast, and feet that slide or sink into the floor.
- **Safe by default.** Off until you turn it on, never overwrites a clip without asking, and every change is one Studio undo.

> **Status: public beta.** Tested on Windows, with Claude Code, Claude Desktop and Codex. Expect rough edges, and please [report problems](https://github.com/Barenton/keywright/issues). See [Limitations](docs/limitations.md) for what isn't supported yet.

## Contents

- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Tools](#tools)
- [Safety](#safety)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [License](#license)

## Quick start

### Requirements

- [Roblox Studio](https://create.roblox.com) on Windows. macOS hasn't been tried yet.
- [Node.js](https://nodejs.org) 22 or later.
- An AI app that supports MCP.

The AI app can run on Windows, or inside WSL while Studio runs on Windows.

### Let your AI app install it

If your AI app can run commands on your computer itself, as Claude Code and Codex can, paste this to it:

> Install Keywright for Roblox Studio: run `npx -y keywright@latest setup`, ask me before adding Keywright to any AI app it finds, and tell me what is left for me to do.

An app whose commands run in a separate virtual machine, such as Claude Desktop's, can't reach Studio's plugins folder: install it yourself, below. It can use Keywright once that's done.

Then [turn on agent access and pair](#3-turn-on-agent-access-and-pair).

### Or install it yourself

#### 1. Install the plugin

```sh
npx -y keywright@latest setup
```

This copies the plugin into Studio's plugins folder, then offers to add Keywright to each AI app it finds: Claude Desktop, Claude Code, Codex and Cursor. It changes only Keywright's entry and keeps a copy of each file it changes. Studio loads the plugin on its own; if the **Keywright** button doesn't appear on the Plugins tab, restart Studio.

On Windows, if PowerShell says scripts can't be run, type `npx.cmd` instead of `npx`, or use Command Prompt.

#### 2. Add Keywright to your AI app

Skip this for any app `setup` added Keywright to; restart that app. Otherwise, for Claude Code, available in every project:

```sh
claude mcp add --scope user keywright -- npx -y keywright@latest
```

Most other apps take an entry like this in their MCP settings:

```json
{
  "mcpServers": {
    "keywright": { "command": "npx", "args": ["-y", "keywright@latest"] }
  }
}
```

`setup` also prints the entry for Codex, the full path to `npx` for apps that can't find it, and the `wsl.exe` form that apps on Windows need when Keywright runs inside WSL. Restart the app, or reconnect its MCP servers, so it starts Keywright.

#### 3. Turn on agent access and pair

1. In Studio, open a place, click **Keywright** on the Plugins tab, and click **Turn on agent access**. Access is off until you turn it on, separately for each place.
2. **The first time only**, the panel shows a pairing code. It works once, within 5 minutes of being registered. Tell your AI app *"Pair Keywright with code ABCD234XYZ"* (using your code), or run `npx -y keywright@latest pair ABCD234XYZ`.

The panel then says **Connected to the broker**, and Studio remembers the pairing.

<details>
<summary>Without npm</summary>

Download [`keywright.mjs`](https://github.com/Barenton/keywright/releases/latest/download/keywright.mjs) and [`Keywright.rbxm`](https://github.com/Barenton/keywright/releases/latest/download/Keywright.rbxm) from the latest release into one folder, keep them together, and run `node keywright.mjs setup` there. It prints the settings for your AI app with that file's path, and every command works the same with `node keywright.mjs` in place of `npx -y keywright@latest`.

</details>

### Make your first animation

Add an R15 rig to your place, for example from **Rig Builder** on the **Avatar** tab, and ask your AI app:

> Using Keywright, make a 1-second looping walk cycle for the rig in my place and save it as "Walk".

Open the saved clip in the Animation Editor to watch it. The [guide](docs/guide.md) has tips, and explains what the agent can do.

### The Keywright skill

Your agent gets Keywright's animator's guide, the [Keywright skill](skills/keywright/SKILL.md), through Keywright itself: the `get_guide` tool serves it in any AI app, with nothing to install, and agents are told to read it before animating. It covers how to plan key poses, review them after every change, and know when an animation is done.

When `setup` adds Keywright to Claude Code, it also installs the skill in Claude Code's skills folder. For other apps that support skills in this format (a folder with a `SKILL.md`), the npm package carries the folder, under `skills/keywright`.

### Updating

Run `npx -y keywright@latest update` and reconnect Keywright in your AI app, or ask your AI app to update the plugin: its `install_plugin` tool does it from inside Keywright. Your AI app tells you when a newer release is out. To build from source instead, see [Contributing](CONTRIBUTING.md).

## How it works

```
AI app ──> adapter ──> broker <── Studio plugin
           (npx keywright)        (inside Roblox Studio)
```

- **The Studio plugin** does all the animation work. Your animations never leave Studio.
- **The adapter** is what your AI app starts. It gives the agent its tools and passes each request on.
- **The broker** connects adapters to Studio windows. The adapter starts it as needed, and it listens only on your own computer (`127.0.0.1`).

The plugin and the broker trust each other through the one-time pairing, and every connection proves itself before anything is sent.

## Tools

| Tool | What it does |
|---|---|
| `get_workspace` | Lists the connected Studio windows, with their rigs, saved clips and working copies. |
| `pair_studio` | Pairs a Studio window with the code its panel shows, once per Studio install. |
| `inspect_rig` | Describes a rig: its joints, how they connect, and their rest positions. |
| `open_animation` | Opens a working copy, blank or copied from a clip. The original is never changed. |
| `read_animation` | Reads a working copy: its settings, and the poses or keys of chosen joints. |
| `edit_animation` | Applies a batch of edits: all or nothing, and one Studio undo. |
| `validate_animation` | Checks a working copy for errors that stop a save, and measures what to look at. |
| `preview_animation` | Samples a working copy on a hidden copy of the rig, with an optional picture of the pose. |
| `save_animation` | Saves a working copy as a new clip for the Animation Editor. |
| `discard_animation` | Throws a working copy away. |

Every argument and all 31 edit operations are in the [tool reference](docs/tools.md).

## Safety

- **Off until you turn it on**, for each place, and you can turn it off at any time.
- **Nothing is overwritten without asking.** Saving makes a new clip. Replacing one needs you to click **Replace the clip** in the panel.
- **Every change can be undone** with one Studio undo.
- **Keywright's connections stay on your computer.** Studio, the broker and the adapter talk only over `127.0.0.1`, web pages are turned away, and Keywright itself uses no online service or account. What the agent reads, such as poses and clip names, goes to your AI app, which may send it to its model provider as it does the rest of your conversation.
- **The agent can't run code.** No tool runs Luau or touches your files.

Keywright can't protect you from harmful software already running under your user account. Try it in a copy of your place or a fresh baseplate first. The details are in [Security](docs/security.md).

## Documentation

| | |
|---|---|
| [Guide](docs/guide.md) | Making animations: tips, the two kinds of clip, and the edits |
| [Keywright skill](skills/keywright/SKILL.md) | How an agent should direct an animation, for apps that support skills |
| [Tool reference](docs/tools.md) | Every tool and argument, as your AI app sees them |
| [Errors and findings](docs/errors.md) | What each error code and validation finding means |
| [Troubleshooting](docs/troubleshooting.md) | Common problems, and the command-line tools |
| [Security](docs/security.md) | Pairing, the connection, and what an agent can do |
| [Limitations](docs/limitations.md) | What isn't supported or tried yet |
| [Performance](docs/performance.md) | Measured speed, reliability and accuracy |
| [Testing](docs/testing.md) | What has been tested, and how |
| [Changelog](CHANGELOG.md) | What changed in each release |

## Contributing

Bug reports and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers building from source, the code layout, the tests and releasing. Please report security problems privately, as described in [Security](docs/security.md#reporting-a-problem).

## License

[MIT](LICENSE)
