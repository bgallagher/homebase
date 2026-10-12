# Android Stage A0: spike results

Decision record for the Android stack (see the plan in the repo history and `android/README.md`). Spikes are throwaway; only the findings are kept here. Everything run against the real server was read-only.

## S1: SSH library (sshj) against Tailscale SSH: PASS on the JVM (12 Oct 2026)

Setup: plain JDK 21 (Temurin), `sshj 0.41.1` + BouncyCastle 1.84 + asn-one 0.6.0 + slf4j 2.0.17, single-file Java program, run from the Mac against `hetzner` (Ubuntu, Tailscale SSH, root).

| Check | Result |
|---|---|
| SSH `none` authentication (what Tailscale SSH accepts, no key or password) | works; `isAuthenticated() == true` |
| Server identification | `Tailscale` |
| Host key available to a verifier callback (for our trust-on-first-use sheet) | yes: Ed25519, fingerprint readable |
| Connect + auth latency | 677 ms + 262 ms (includes JVM cold start; Mac Overview target is < 2 s) |
| Plain `exec` without a pty | works, exit status returned |
| Keepalive | `setKeepAliveInterval(15)` accepted (behaviour over a dropped link still to test on the phone) |
| Stream 8 MiB into a remote command's stdin | 8,388,608 bytes sent, remote counted exactly 8,388,608 (2.4 s); the byte-count check Files uploads need is possible |
| `docker logs -f` over a pty, close the channel **after sending Ctrl-C (0x03)** | remote follower gone (0 left) |
| Same, **close only** | remote follower LEFT RUNNING (2 processes); cleaned up by the spike |

Conclusions:
- sshj works with Tailscale SSH using plain `none` auth. No SSH-library fallback is needed on this evidence.
- Cancelling a stream must send Ctrl-C through a pty first, then close, exactly as the Mac's `OpenSSHTransport.stream` does. Closing alone leaks the remote process (same finding as on the Mac). The Kotlin `stream` must implement the Ctrl-C step and the `logs` probe stays a release gate.
- Not yet proven: Tailscale "check" mode re-auth banner/URL handling (the test server is not in check mode), password and key auth, Ed25519 OpenSSH private-key import, and anything on Android itself (BouncyCastle provider registration, R8, the phone's Tailscale routing).

## S1b: the same on the Pixel 10 Pro (Android 17, API 37) over its own Tailscale app: PASS (12 Oct 2026)

Throwaway app (AGP 9.4.1, Gradle 9.8.1, compileSdk 36, minSdk 26, plain Java Activity), sshj 0.41.1 + bcprov/bcpkix 1.84 + slf4j-nop, on Wi-Fi with the Tailscale VPN active, connecting to hetzner's tailnet address.

| Check | Result |
|---|---|
| `none` auth against Tailscale SSH | works, same Ed25519 host key as from the Mac |
| Connect + auth | 706 ms + 200 ms |
| Plain exec | works |
| 4 MiB through remote stdin | counted exactly (1.2 s) |
| Ctrl-C then close | 0 followers left; **close only** leaves 2 (same as JVM and Mac) |
| Debug APK size, R8 off | 4.8 MB with sshj + BouncyCastle |

Android notes:
- The platform's own "BC" provider is cut down. Remove it and insert the full BouncyCastle provider first (`Security.removeProvider("BC"); Security.insertProviderAt(new BouncyCastleProvider(), 1)`) before the first connection.
- The **first** connection after the phone's Tailscale had been idle timed out at 10 s (the path to the server was still being set up over DERP). The retry a minute later connected in under a second. The app should use a longer first-connect timeout (about 20 to 30 s), retry once automatically, and say "Waiting for Tailscale…" rather than failing.
- Not yet tested on the phone: Tailscale "check" mode, key and password auth, R8 with the BouncyCastle provider swap, keepalive over a Wi-Fi/mobile switch.

## S2: terminal view, ConnectBot termlib 0.3.13 on the Pixel 10 Pro: PASS (12 Oct 2026)

Compose app: termlib `Terminal` + `TerminalEmulatorFactory` fed by an sshj shell channel (`xterm-256color` pty, `none` auth), with an extra-keys row (Esc, Tab, ^C, arrows, `| ~ / -`). Commands run were read-only (`htop`, `vim -R /etc/os-release`), scripted through the same input path as typing; checked from screenshots.

| Check | Result |
|---|---|
| Login banner, bash prompt, scrollback text | correct |
| `htop` (alternate screen, 256-colour bars, coloured columns, F-key bar, live refresh) | renders correctly |
| `vim -R` (alternate screen, blue `~` filler, status line, cursor) | renders correctly once the pty size matches the view |
| Soft keyboard + `adjustResize`, extra-keys row above the IME | works; the row scrolls horizontally |
| Licence | Apache-2.0 (Maven POM and GitHub); libvterm inside is MIT |
| Maintenance | last push 10 Oct 2026, by the ConnectBot maintainer; small project (27 stars), so pin the version |
| API fit | `writeInput(bytes)`, `onKeyboardInput(bytes)`, `onResize(cols, rows)`, `setAnsiPalette(IntArray)`, `setDefaultColors`, `applyColorScheme`, pinch zoom, selection, hyperlink callback: our 45 shared themes map straight onto it |

Findings to carry into A5:
- **The pty size must come from the emulator.** The view reported 64 x 27 (portrait, keyboard open, 11 sp). Allocating the pty at 80 x 24 and forwarding later resizes made vim's status line and wrapped lines wrong. Allocate with `emulator.dimensions` at connect, and forward every `onResize` with `changeWindowDimensions`. `onResize` fires several times while the layout settles (64 x 56, 64 x 60, 64 x 27), so debounce.
- Portrait width is tight (64 columns): htop's TIME column was cut. Offer a font-size control, pinch zoom and landscape, and consider a smaller default size.
- The module needs `compileSdk` 37 (termlib and Compose 1.12 require it), which AGP 9.4.1 supports.
- Debug APK with Compose, termlib native libraries for all ABIs and no R8: 32 MB. Expect a fraction of that with R8 and ABI splits.
- Not tested yet: selection handles and the copy flow, hardware keyboard, Ctrl modifier toggle, background behaviour.

## Decision so far

- **SSH: sshj 0.41.1 + BouncyCastle 1.84.** Proven on the JVM and on the phone against Tailscale SSH.
- **Terminal: ConnectBot termlib 0.3.13.** Termux terminal-view and xterm.js stay as documented fallbacks and are no longer needed on this evidence.
- **Build toolchain:** AGP 9.4.1, Gradle 9.8.1, Kotlin compose plugin 2.4.21, Compose BOM 2026.09.00, compileSdk 37, minSdk 26.

## Still open before or during A1/A2

- R8/minify keep rules for sshj, BouncyCastle (the provider swap) and termlib's JNI; verify on a release build.
- Key and password authentication, OpenSSH private-key import, Tailscale "check" mode banner handling.
- S3: a foreground service keeping a session alive with the screen off, and reconnect after a Wi-Fi to mobile switch (A5, but test the transport part early).
- Spike code and jars live only in the session scratchpad; the A1 Gradle project is a clean start.

## Stage A1 result (12 Oct 2026)

`android/core` (pure Kotlin/JVM) ports the MVP inventory and passes **136 tests**: all overview, docker and updates golden
fixtures, the attention rules, the session and policy tests, the streaming and Ctrl-C-marker parsers, apt, the command
library (including real `/bin/sh` runs), reboot, themes and palette contrast over all 45 bundled themes, and the terminal
output filter. Deviations from the plan: commands are read from the spec at runtime instead of being duplicated, and
`themes.json` stays in the Mac app's resources (SwiftPM cannot copy from outside its target) and is shared from there.

## Stage A2 result (12 Oct 2026)

`android/ssh` (sshj 0.41.1 + BouncyCastle 1.84, pure JVM) and `android/probe` run against the real server from the Mac:

| Probe check | Result |
|---|---|
| `overview` | connect 0.5 s, first poll 1.0 s, second 0.9 s; parsed hetzner (Ubuntu 24.04.5, 4 cores), CPU % from two polls |
| `hostkey` | an untrusted server is refused with its fingerprint; a trusted one connects; a changed key is blocked and never offered |
| `stream-check` | `docker logs -f` over a pty, cancelled: **no follower left** on the server (Ctrl-C then close) |
| `stream-marker` | `StreamRunner` reports the command's own exit code (3) through the real pty marker; the marker line is not shown |
| `shell-check` | a shell opens at 24 x 80, follows a resize to 30 x 100, and ends with `RemoteExit(0)` |

The fingerprint sshj gives equals `ssh-keygen -lf` (`SHA256:WVoNXEYG9GL78kRUJLzuwQQmXNsrazBfkwlK+/0qzM8` for hetzner), and a unit test
pins it against two keys generated with ssh-keygen. `core` gained `ReconnectPolicy` (1/2/4/8/15 s, 5 attempts, 10 s of uptime resets
the budget; only a lost connection retries). Tests: core 141, ssh 8.

Probe lesson: a terminal echoes what is typed, so a check must wait for text only the OUTPUT contains (the first version of
`shell-check` raced the echo and read the size too early).

## Stage A5 first cut: terminal on the Pixel 10 Pro (12 Oct 2026)

termlib terminal on the real server: pty at the emulator's size, login banner, prompt, typing through the soft keyboard, extra-keys row, output highlighting (error words, IPs, percentages), tab strip, Read-only gate, foreground service ("N SSH sessions open"), and a session that survived 45 s of screen-off. Found on device: Android's regex engine rejects `(?U)` and reads `[:` as a POSIX class (fixed in core `OutputHighlighter`). Not yet tried: Wi-Fi/mobile switch and the reconnect card, full-screen programs through this app (htop/vim worked in the spike), landscape layout, font size control.

## Stage A3/A4 follow-up: sign-in, settings, Overview polish on the Pixel (12 Oct 2026)

Done and checked on the phone: SSH key (system file picker, no storage permission) and password sign-in with secrets encrypted by an Android Keystore AES-GCM key (one file per server, never in servers.json); key import tested with real `ssh-keygen` keys (Ed25519, RSA, ECDSA, passphrase-protected: needs-passphrase and wrong-passphrase are caught before any connection); Server settings (rename, change sign-in with a connection test, trusted host key with Forget, remove); the last Overview reading is cached per server and shown stale at once on launch; the unreachable screen says when no VPN is active. Checked only by compiling, not on a device: the wide layout (navigation rail, two-column Overview from 840 dp) and a real password/key login against a server (the test server only offers Tailscale SSH).

## Docker overview on the Pixel (12 Oct 2026)

A Docker tab (bottom bar: Overview, Docker, Terminal, More) polls `DockerSession` every 10 s while it is on screen, over the same SSH connection as the Overview. Checked on the phone against the real server: 10 stacks and 15 containers grouped by compose project, usage per container, site links with scope tags, the stack page (status, working folder, containers with image, ports and Docker's status text), pull-to-refresh and system Back. Core gained the pure helpers `LinkScope`, `DockerStack.status()`, `DockerSnapshot.summary()`, `LetterTile.hue` and `DockerContainer.usageText` (5 tests), mirrors of the Mac app's. Not built yet: the empty, not-installed and unreachable states were only compiled, and container actions, logs, files and bookmarks editing.
