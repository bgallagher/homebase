# Android feasibility note (Stage 1)

Purpose: confirm `SSHTransport` (run, stream, later openPTY) is not Mac-specific. **Desk research only; nothing here was run on Android.**

## SSH
- `sshj` (JVM/Android) supports public-key auth, exec channels (maps to `run`), streamed channel output (maps to `stream`) and PTY shells.
- Android has no system `ssh` and no `~/.ssh/config`, so keys come from an in-app import flow stored in Android Keystore-backed storage. Host aliases become plain `Server` host/port/user fields.
- Consequence for Core: `Server` must carry explicit user, port and key reference. It cannot depend on an ssh_config alias. Today `Server` only has `host` and an optional alias, so add `user` and `port` before Stage 3.

## Terminal
- Termux `terminal-view` and `terminal-emulator` are Apache-2.0 libraries that render a terminal from a byte stream, which suits an sshj PTY channel.
- Both the Mac and Android terminals consume a PTY byte stream, so the interface is `openPTY` returning input/output streams plus a resize call.

## Still to verify (needs a device or emulator)
1. sshj connects to a real server with an ed25519 key on Android.
2. Termux terminal-view renders vim and htop from an sshj PTY.
3. Connection survives app backgrounding, or fails in a way the UI can recover from.

## Result
No blockers found for the transport interface. Add `user`/`port` to `Server` and an `openPTY` method to `SSHTransport` when the terminal stage starts.
