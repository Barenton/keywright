# Troubleshooting

| What you see | What to do |
|---|---|
| Edits or saves fail with `STUDIO_NOT_IN_EDIT_MODE` | Studio refused to start an undo step, and Keywright makes no change you couldn't undo. Close the Animation Editor if it's open, especially if it's playing a clip, then try again. Otherwise finish whatever is in progress in Studio, such as a dialog or a drag. If it says an earlier Keywright change hasn't finished, wait for it, or reload the plugin. |
| The agent can't find a Studio window | Check that the Keywright panel says **Connected to the broker**. If you just reinstalled the plugin, reconnect Keywright in your AI app. |
| The panel says the plugin or the adapter is older | Update the one it names, as in [Updating](guide.md#updating). The panel reconnects on its own once they match. |
| The panel says **Pairing is needed again** | Turn agent access off and on to get a new code, then pair again: tell your AI app the code, or run `npx -y keywright@latest pair <code>`. |
| The pairing code stopped working | A code works once, within 5 minutes of being registered, and registering another code (for example one typed wrong) replaces it. Turn agent access off and on for a new one. |
| The panel says **Another program is using the broker port**, or the agent gets `BROKER_PORT_CONFLICT` | Another program is using port 47318, which Keywright needs. Close it, then turn agent access off and on. |
| PowerShell says `npx` **cannot be loaded because running scripts is disabled** | Type `npx.cmd` instead of `npx`, or use Command Prompt. Nothing needs changing in Windows' settings. |
| An AI app's own commands **can't install** Keywright, or can't start | Some apps run commands in a separate virtual machine, which can't reach Studio's plugins folder. Run `npx -y keywright@latest setup` yourself; it offers to add Keywright to the apps it finds. |
| The **Keywright** button doesn't appear in Studio | Restart Studio. If it still doesn't, run `npx -y keywright@latest install-plugin` again and read what it says. |

What each error code means is in [Errors and findings](errors.md).

## Command-line tools


| Command | What it does |
|---|---|
| `npx -y keywright@latest setup` | Installs the plugin, offers to add Keywright to each AI app it finds, and prints the settings for others. `--add-to found` (or a list: `claude-desktop,claude-code,codex,cursor`) adds it without asking, for an agent that has asked you. |
| `npx -y keywright@latest update` | Updates: installs the newest plugin and says what is left, which is reconnecting Keywright in your AI app. |
| `npx -y keywright@latest install-plugin` | Installs or updates the plugin only. Add `--folder <path>` to install somewhere else. |
| `npx -y keywright@latest pair <code>` | Pairs a Studio window, with the code its panel shows. |
| `npx -y keywright@latest status` | Starts the broker if needed and prints its state. |
| `npx -y keywright@latest rotate` | Replaces the broker's secret. Every Studio window must pair again afterwards. |
| `npx -y keywright@latest version` | Prints the version. |

`npx -y keywright@latest --help` lists them all. With the downloaded files, use `node keywright.mjs` in place of `npx -y keywright@latest`, in their folder; in a source checkout, `node dist/src/cli.js`.
