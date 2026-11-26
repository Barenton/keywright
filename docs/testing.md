# Testing

What has been tested, and how. The measured numbers are in [Performance and accuracy](performance.md).

## Automated

Run on every push by CI (`npm test` and `npm run test:luau`):

- the handshake, pairing and rotation, and refusal of unauthenticated or forged messages;
- routing and timeouts, and a single broker when twenty adapters start at once;
- the MCP adapter end to end, against a stand-in plugin;
- the single-file release, run as someone who downloaded it would run it;
- every edit operation, the clip checks, saving and working copies, and pose pictures;
- the plugin's settings when several Studio windows write at once, or a write is lost;
- that previews never move or change the real rig.

The Luau tests run outside Studio, under [Lune](https://lune-org.github.io/docs), so they need no Studio window.

## Measured in Studio

On Windows, with the adapter in WSL, on rigs with `Motor6D` joints and rigs with `AnimationConstraint` joints:

- 10,000 round trips with none lost;
- sampled poses within 0.01° of the stored values;
- the same results from both joint types;
- clips that come back unchanged after a save and reopen;
- a session's network traffic staying on `127.0.0.1`.

## Checked in Studio by hand

- pairing, from a terminal and through an AI app, and reconnecting after a plugin reload;
- two Studio windows on two places, each remembering its own access, also when both are switched on at the same moment;
- one undo reverting exactly one batch, and a failed batch leaving nothing behind;
- a save refused for a clip with structural errors, and an R6 rig refused with its reason;
- pose pictures that match the Animation Editor;
- saved clips that load and play in the Animation Editor;
- edits and saves with the Animation Editor open, and during Play and Run;
- the beta demonstration (a three-second wave with a hold, adjusted from the pose pictures, validated and saved) in Claude Code, Claude Desktop and Codex, with Claude Code and Codex running in WSL;
- WSL with mirrored networking: Studio reaches the broker in WSL with no extra step, and the broker can't be reached from the network.

## Not tested yet

- macOS;
- Studio screenshots, which are switched off;
- AI apps other than Claude Code, Claude Desktop and Codex.
