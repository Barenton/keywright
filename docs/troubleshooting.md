# Troubleshooting

| What you see | What to do |
|---|---|
| Edits or saves fail with `STUDIO_NOT_IN_EDIT_MODE` | Studio refused to start an undo step, and Keywright makes no change you couldn't undo. Finish whatever is in progress in Studio, such as a dialog or a drag, and try again. If it says an earlier Keywright change hasn't finished, wait for it, or reload the plugin. |
| The agent can't find a Studio window | Check that the Keywright panel says **Connected to the broker**. If you just reinstalled the plugin, reconnect Keywright in your AI app. |
| The panel says the plugin or the adapter is older | Update the one it names, as in [Updating](guide.md#updating). The panel reconnects on its own once they match. |
| The panel says **Pairing is needed again** | Turn agent access off and on to get a new code, then pair again: tell your AI app the code, or run `node keywright.mjs pair <code>`. |
| The pairing code stopped working | A code works once, within 5 minutes of being registered, and registering another code (for example one typed wrong) replaces it. Turn agent access off and on for a new one. |
| The panel says **Another program is using the broker port**, or the agent gets `BROKER_PORT_CONFLICT` | Another program is using port 47318, which Keywright needs. Close it, then turn agent access off and on. |
| The **Keywright** button doesn't appear in Studio | Restart Studio. If it still doesn't, run `node keywright.mjs install-plugin` again and read what it says. |

What each error code means is in [Errors and findings](errors.md).

## Command-line tools

From the folder with `keywright.mjs`:

| Command | What it does |
|---|---|
| `node keywright.mjs setup` | Installs the plugin and prints the settings for your AI app. |
| `node keywright.mjs install-plugin` | Installs or updates the plugin only. Add `--folder <path>` to install somewhere else. |
| `node keywright.mjs pair <code>` | Pairs a Studio window, with the code its panel shows. |
| `node keywright.mjs status` | Starts the broker if needed and prints its state. |
| `node keywright.mjs rotate` | Replaces the broker's secret. Every Studio window must pair again afterwards. |
| `node keywright.mjs version` | Prints the version. |

`node keywright.mjs --help` lists them all. In a source checkout, use `node dist/src/cli.js` in place of `node keywright.mjs`.
