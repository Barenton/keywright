# Security

Keywright lets a program on your computer change animations in an open Roblox Studio place. This page says what stops anything else from doing the same, and what an agent can and cannot do once it is connected.

## What it protects against

- **Web pages.** A page you visit cannot reach the broker, even though it runs on your computer.
- **Other computers.** Nothing outside your computer can connect.
- **Other programs on your computer that don't have your pairing secret,** including other users' programs on a shared computer.
- **An agent doing more than editing animations.** It can't run code, read your files, or overwrite your work without you agreeing.

It does **not** protect against harmful software already running under your own user account. Such software can read the same secret files the adapter reads, and Studio's plugin settings. Nothing that runs as you can be kept out by a program that also runs as you.

Two more limits:

- **Changing the port.** Each connection's handshake is proved, but the messages after it aren't signed one by one. If the broker is moved to another port while a Studio window still connects to the old one, a program on that old port could pass the handshake between them and then send requests of its own. Change the port for Studio and the AI app together, and turn agent access off until both use the new one.
- **Windows, with `KEYWRIGHT_HOME` set.** On Windows the secret and credentials take the permissions of the folder they're in. Your user folder, the default, is closed to other users; a `KEYWRIGHT_HOME` elsewhere should be too.

## The connection

```
AI app ── adapter ──┐                      ┌── Keywright plugin (Studio window)
                    ├── broker, 127.0.0.1 ─┤
AI app ── adapter ──┘                      └── Keywright plugin (Studio window)
```

- **Loopback only.** The broker listens on `127.0.0.1`, port 47318, and on nothing else. It doesn't open a port to your network, and it never connects out.
- **Browsers are turned away.** A connection must ask for the broker's own path with a loopback `Host`, and must not carry an `Origin` header. Browsers always send `Origin` on a WebSocket, and Keywright's own clients never do, so a web page's connection is refused before anything is read.
- **Both sides prove who they are before anything else is sent.** Each connection starts with a handshake: the two sides exchange random nonces, and each proves it holds the shared key with an HMAC-SHA256 over its role and both nonces. Binding in both nonces and the role means a recorded handshake can't be replayed or reflected back. Proofs are compared in constant time. A connection that sends anything else first, sends binary data, or doesn't finish within 5 seconds is closed.
- **What each side may send is fixed.** Adapters send requests for the tools; plugins send only their session's description and answers to requests sent to them. An answer counts only from the connection the request went to. Messages over 8 MiB are refused.

### The keys

- **Adapters** prove they hold your **secret**: 32 random bytes made the first time Keywright runs, kept in a file in your own user folder. On macOS and Linux the file and its folder can be read only by you; on Windows, your user folder is closed to other users. It lives in `%APPDATA%\keywright` on Windows, `~/Library/Application Support/keywright` on macOS, and `~/.config/keywright` on Linux and WSL. It never crosses the connection.
- **Studio windows** prove they hold a **credential** made by pairing, once per Studio install:
  1. When agent access is turned on and there is no credential yet, the panel shows a one-time code.
  2. You run `node keywright.mjs pair <code>`, or give the code to your AI app, whose adapter registers it with the `pair_studio` tool. Either way, the program registering it proves it holds your secret first. A code that hasn't been registered this way is worth nothing, and an agent can't make one up: only the panel shows it, and it works once.
  3. The plugin connects using the code as a key. From the code and the handshake's nonces, the two sides each work out the same new credential key, so the key itself is never sent.

  A code is valid for 5 minutes from when it is registered, is used once, and is given up after 5 wrong proofs. Wrong proofs from any connection count, so another program can use up a waiting code; that only means pairing again, while counting them per connection would let a program guess with many connections. Registering a code replaces any code still waiting, so a code typed wrong makes the right one stop working: turn agent access off and on for a new one. The broker keeps credentials beside the secret, and Studio keeps its credential in its plugin settings.

  On a computer shared with other users, give the code to your AI app rather than running `pair <code>`: a command's arguments can be seen by other users while it runs, and npm also writes them to its own log.
- **Starting over:** `node keywright.mjs rotate` replaces the secret, and every stored credential stops working with it. Every broker using that folder stops within two seconds, whatever port it is on, so none goes on accepting the old secret. Every Studio window must then pair again.

## What an agent can do in Studio

Only the [tools](tools.md), and within them:

- **Nothing until you turn it on.** Agent access is off until you switch it on in the Keywright panel, separately for each place, and you can switch it off at any time. A place that has never been saved to Roblox can't be told apart from other such places, so access there is off each time it opens.
- **Animations only.** The tools read rigs and clips and edit working copies of clips. No tool runs Luau, changes scripts or other instances, or reaches your files or the network.
- **Originals stay as they are.** Editing happens in a working copy. The clip it was opened from is never changed by editing.
- **Saving never overwrites.** A save makes a new clip, and a name that is already taken is refused. Replacing an existing clip needs a person to click **Replace the clip** in the panel; the agent can only ask. If the clip has changed since the agent asked, the replacement is refused.
- **Everything can be undone.** Each batch of edits, each save and each discard is one Studio undo step. If Studio won't start an undo step, Keywright refuses the change.
- **No stale edits.** Every change names the revision it was made against, and a change against an older one is refused.
- **Previews don't touch the rig.** A preview plays the clip on a hidden copy of the rig, which is removed afterwards. The rig and the camera are never moved.

## What reaches the AI app

Keywright's own connections never leave your computer, but what the agent reads goes to your AI app. That app may send it on to its model provider, as it does the rest of your conversation, and what it does with it is up to the app. So does anything you tell it, such as a pairing code. A pairing code is only useful within 5 minutes and on your computer.

- **Text.** Tool results are JSON text: joint names, numbers, poses, clip names and messages.
- **Pose pictures**, which the adapter draws itself from the joint positions Studio reports. They are not taken from your screen.
- **No screenshots.** The code to take a Studio screenshot exists but is switched off, and stays off until its behaviour in Studio has been checked independently. The adapter also checks everything that comes back from Studio: an image is passed on only if one was asked for and it is a single, complete, still PNG of the expected size. In text, the adapter replaces base64-encoded PNG data, `data:image/` addresses, and fields named `images` or `png_base64`. It looks for those forms specifically; it doesn't decode everything a result could contain.

## Reporting a problem

If you find a way around any of this, please open an issue on GitHub. Leave out the details that would let someone else use it, and ask for a way to send them privately.
