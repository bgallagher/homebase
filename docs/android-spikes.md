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

## Bookmarks on the Pixel (12 Oct 2026)

More > Bookmarks lists every service with Homepage labels grouped by where the link works (Local, Tailscale, Public), with search, Open, Copy address, Edit and Remove; Add is the + button, and each Docker card has a bookmark button. A change reads the compose file that defines the service, edits only its labels, shows the diff in a confirmation sheet (with the apply command), and saves through the sha-guarded, server-checked write (`.rackoon.bak` kept). Save and apply then runs the stack's `up -d`. Read-only mode disables all of it with a banner. Core gained the compose-file stack from the Swift core (ComposeLabels, StackFiles, StackFileCommands, StackFileSession, LineDiff) plus `BookmarkEditor`, with the Swift tests ported (186 core tests).

Checked on the phone against the real server up to the confirmation sheet (the real AdGuard compose file was read and a one-line diff shown; cancelled, nothing written). The write path itself was proven by `probe bookmark-test` on a throwaway stack under /tmp: edit, server-side compose check, save, backup kept, mode kept, changed-on-server guard, removal, invalid file refused, cleanup. That probe found a real bug shared with the Mac app: removing the last label also deleted any comment or blank line that followed the labels. Fixed in both cores with regression tests. Not tried on the phone: Save and apply on a real stack (it recreates a container), and Add with the stack picker.

## Docker actions and live Output (D1, 12 Oct 2026)

The stack page now has the design's Containers and Output tabs. Each container has Shell, Restart, Rebuild (when it has a compose service) and a menu with Stop…; stopped containers have Start; the stack menu has Pull images, Update, Restart all, Rebuild and Recreate…. Every one goes through the confirmation sheet (exact command, "run as user", destructive ones styled as such; Start runs directly like the Mac) and streams into the Output tab: a read-only termlib view that starts the run only after it has reported its size, with Cancel (Ctrl-C reaches the remote command) then Close. Read-only disables everything with a banner and "Disabled: Read-only mode is on". Shell opens a terminal tab running `docker exec -it` through the new `ServerConnection.openShell(cols, rows, command)`. The words and the "why it's unavailable" rules are pure core functions (`ActionPrompts`), ported from the Mac with tests.

Proven on the real server by `probe compose-test` (all checks pass: streamed and plain restart/update/pull/rebuild/recreate on a throwaway stack, a failing command's real exit code, Read-only refusal, full cleanup) and `probe exec-shell-check` (a command and an interactive program on a real pty with their exit statuses). Driven through the whole UI on an emulator in demo mode (confirm, run, output, cancel, Read-only, Shell). Not yet done: the same on the real phone against the sandbox stack (the phone was unplugged). Per-container Recreate from the design's menu is not built: the Mac has stack-level Recreate only and the spec has no per-service recreate command.

## Logs (D2, 12 Oct 2026)

The stack page's Logs tab follows every container of the stack at once (`LogFollower` in core: one `docker logs -f` per container on its own pty connection, lines joined across chunk boundaries, merged in arrival order, tagged with the compose service, capped at 2000, flushed in 100 ms batches, Ctrl-C on stop). The view follows the Logs and LogsFiltered boards: container chips with colour dots, level chips with live counts (All/Error/Warn/Info; only explicit level markers count, so prose mentioning "error" is not red), search, a Following/Paused pill, rows with time, container, level and message (two lines, an arrow expands long ones), "Latest · N new", and Copy visible logs. Scrolling away pauses following by itself; getting back to the end or tapping Latest resumes it. Following runs only while the tab is on screen and the app is in the foreground. 197 core tests (LogFollower and LogView are pure and tested with fake streams).

`probe logs-check` follows two real containers merged for 6 s and proves one follower per container runs on the server while following and none are left after stop. Driven through the UI on the demo emulator: merge, container focus, level filter with counts, pause by scrolling, Latest.

## compose.yaml and .env editor (D3, 12 Oct 2026)

Each stack page has a Files section (compose file(s) and `.env`, as on the StackSingle board) and a "View compose.yaml" item in the container menu. The editor is a code view (monospace, no soft wrap, line numbers, YAML/env colours from the terminal theme, green bands behind changed lines, red behind failing ones, auto-indent, a key row with Tab as two spaces and the punctuation a phone keyboard hides). After a 600 ms pause in typing the exact current text is checked on the server (`docker compose config` against a temp copy, so relative paths and interpolation behave as on deploy); the checklist (YAML syntax, Compose schema, docker compose config, warnings; `.env` syntax is also checked locally) only counts for the text it was run on, and Save is enabled only when that check passed. Save and Save & redeploy go through the confirmation sheet (diff plus the `up -d` command), keep `<file>.rackoon.bak`, and a redeploy leaves the editor for the stack's Output tab. If the file changed on the server in between, nothing is overwritten: Reload from Server or Keep Editing. Leaving with unsaved changes asks first; drafts live in the view-model so rotation keeps them. Read-only: viewable, not editable, every save disabled.

Core gained `EditorChecks`, `EnvSyntax`, `SyntaxHighlighter` (ported with their Swift tests) and `StackEditor` (the editor's rules as a tested state machine: stale check results, debounce, conflict path, save gating), 226 core tests. `probe env-test` proves the .env write path on a real server on a throwaway stack: missing .env, create (mode 600), `--env-file` validation, the not-exists guard when a file appears underneath, edit with backup and carried-over permissions. Driven on the demo emulator end to end: open, type, green band, passing checks, a misspelled key blocked with the server's message, Read-only, Save & redeploy streaming into Output, reopen shows the saved text, discard prompt. Not tried: the real phone, large files near the 64 KB cap, a hardware keyboard.

## Delete stack (D4, 12 Oct 2026)

Stack menu > Delete stack… opens the destructive sheet (ConfirmDestructive board): what is removed, two opt-in extras that lose data (named volumes; the stack's folder, ticked by default only when `StackRemoval.folderProblem` is null), the exact command (four lines with "Show full command", because the folder step is long), and the stack's name typed in whenever volumes or the folder are included. It streams into the stack's Output tab; the stack stays on screen while its containers vanish; on success the page closes; on failure or cancel it stays listed as "Not started" with its Output readable, so files are never orphaned. Read-only disables it.

The folder-delete safety rules are ported from the Mac with every test, including the real `/bin/sh` runs with a stub `docker` and symlink traps (a symlinked folder or compose file cannot redirect the delete; a symlinked parent is fine; each failed guard says why and exits 6). The folder step now lives in the spec as `compose_down_folder` (before, only Swift had it); both languages read it and the Swift test pins its copy to the spec. `probe delete-test` ran the real delete on a real server: a container-written (root-owned) bind-mount folder is removed, the second stack keeps running, a delete without confirmation or in Read-only changes nothing, and everything is cleaned up. Driven on the demo emulator: Read-only greys the menu entry; the sheet; the button stays disabled until the name matches; the run streams and the stack disappears from the list.
