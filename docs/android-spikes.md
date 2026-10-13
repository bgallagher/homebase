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

## Add container (D5, 12 Oct 2026)

The Docker page has the design's "Add container" button (Read-only disables it). The page: a New stack / Existing stack switch. New stack: stack name (checked against the stacks that exist), folder (defaults to where the server's stacks already live, learned from them), and either the form (container name, image, port, volume and environment rows, restart policy) or "Paste compose.yaml" (plus an optional .env, with a one-tap "add the variables compose says are not set"). Existing stack: pick one of the stacks whose compose file Rackoon can edit; the form adds one service as new lines at the end of its `services:` block (the file's own indentation, everything else untouched), merges new variables into its .env without changing existing ones, and refuses an inline `services: {}` or a duplicate name with the reason. Checks run on the server as you type (compose in a scratch folder for a new stack, or on a temp copy of the real file for an existing one; the image on its registry; which ports are in use and by whom, with a free one suggested; whether the container name is taken) and the button stays off until all of them pass, with the reason shown. The files that will be written show below, read-only. Save (or Add) writes the files; Create and start also runs `up -d`, streaming into the stack's Output. Both confirm first (the files or the diff, plus the command). A new stack with no containers is kept on screen as "Not started" until Docker lists it. Two-way editing of the YAML (the Mac's form follows typed YAML) is deliberately not built: a pasted file replaces the form.

Core: `ContainerSpec`, `EnvMerge`, `ComposeInsert`, `NewStack*`, `ContainerChecks` ported with their Swift tests; the `.env` step fragments of the create and check scripts moved into spec/commands.json (the Swift tests pin their copies); `AddContainerDraft` holds the page's rules (12 tests with a fake server): 275 core tests. `probe newstack-test` (real check and create on a throwaway folder: the check changes nothing, create writes files with `.env` at mode 600, refuses an existing folder, a rejected file leaves nothing behind, `up -d` then starts it) and `probe checks-test` (real registry lookups and the listening ports) pass. Driven on the demo emulator: a new stack from the form (created, started, Running), and a service added to an existing stack (diff of new lines only, container appears). Not yet tried: Paste mode and the not-found/in-use states on a device.

## Site icons (D6, 12 Oct 2026)

`FaviconLinks` is ported to the Kotlin core with the Swift tests (page-order ties, apple-touch-icon first, mask-icon and data: links skipped). The phone fetches icons itself (`FaviconStore`: `HttpURLConnection`, redirects followed by hand so every hop is http(s), 256 KB page / 1 MB image caps, 6 s timeouts, no cookies, a trust-all certificate check for this GET only, one fetch at a time) and keeps 128 px PNGs plus `index.json` under `files/Rackoon/favicons/`. A site without an icon is retried after a day; tapping an icon refreshes it. Icons show on stack cards, the stack page header and Bookmarks rows, with the letter tile as fallback. Cleartext http is allowed through a network security config (many bookmarks are plain http on a home network); the icon fetcher is the app's only HTTP client. Tried on the Pixel against hetzner's real bookmarks: AdGuard, AIOMetadata, Dockge and Grafana got their icons, aiostreams (no usable icon) kept its letter. Not yet tried: tap-to-refresh and the daily retry.

## Parity pass: Docker section against the Mac (D7, 12 Oct 2026)

| Mac Docker feature | Android |
|---|---|
| Stack cards, scope-tagged links, status, unhealthy highlight | done |
| Stack actions Pull / Rebuild / Restart / Update / Recreate with the "why disabled" reason | done (`ActionPrompts.blockedReason`) |
| Container Start (direct), Stop and Restart (confirm), Shell, per-container Rebuild | done |
| Live Output tab with Cancel and Close | done |
| Logs: merged follow, per-container focus, level chips, search, pause/Latest/N new, copy | done |
| compose.yaml / .env editor with server checks, diff, Save, Save and Redeploy, conflict handling | done |
| Delete stack with the folder-safety rules and typed name | done |
| Add container: new stack, existing stack, checks | done, but a pasted file replaces the form (no two-way text editing) |
| Bookmarks (add, edit, remove, grouped list) and site icons | done |
| Read-only gating and Intent/Confirmation on every mutation | done |
| Demo mode | debug builds only (not in a release) |

Known differences: no tablet two-pane layout, no keyboard shortcuts, long log lines are not truncated with an expander (the Mac design has it; neither platform has it built). Unproven on a device: Add container's Paste mode and its image-not-found / port-in-use states, Read-only on the phone, the "file changed under you" path, a Wi-Fi drop during a stream, files near 64 KB, hardware keyboard, release build (R8, signing). Outside this plan and still missing on Android: Updates, Commands and Files sections.

## Updates and Reboot (U0 to U4, 12 Oct 2026)

Most of it already existed in the Kotlin core (`UpdatesSession`, `AptAction`, `UpdatesParser`, `RebootSession`, all spec-first), so this was UI, view-model wiring, demo and a probe. New in core: `UpdatesPresentation` (subtitle, "N days ago", stale-lists warning after 3 days, security-first ordering, the capped explicit security list and the reason a button is off, the confirm/Output texts), 7 tests.

The page (More > Updates; the Overview chips for security updates and a needed reboot open it too): subtitle (amber with security updates), stale-lists warning, summary tiles (Available, Security, Held back, Lists refreshed), Install Security Updates / Install All / Refresh Lists, an All/Security filter over the package list (name, suite, old to new version, Security badge), the held-back card and the reboot banner. It reads when opened and after each action (no polling). Every action goes through the confirm sheet (exact command) and streams apt's own output into a read-only terminal with Cancel/Close, then the list is re-read; Read-only greys the buttons with the reason. The More row shows the counts from the Overview's own `##updates`/`##security`. Reboot (Updates banner and the Overview System card): confirm sheet, `sudo -n` precheck, then waits until the kernel boot id differs (10 min cap), with a banner (asking / waiting with a timer / back / timed out / failed); the Overview's failing polls are hidden while it runs, and Updates re-reads when the server is back. A reboot wait is dropped if you switch servers.

Proof: `probe updates-check` on a real server (read-only: reads the list, checks it against the Overview's counts, streams `apt-get -s upgrade` through the real wrapper, and shows a cancelled streamed command leaves nothing behind) passes. Driven on the demo emulator: the list, filter, Install Security Updates with live output (the list shrinks, security drops to 0 and the button turns off), and the reboot flow end to end (the fake server stops answering for about 15 s and returns with a new boot id). Opened on the Pixel against hetzner (up to date: all zeros, the More row says so). Never run against a real server: apt install, `apt-get update` and reboot (as on the Mac). Not yet tried: Read-only on the phone for these buttons, a very long package list, a real sudo/apt-lock failure message.

## Release build (13 Oct 2026)

R8 and resource shrinking are on for release (`app/proguard-rules.pro`: sshj, BouncyCastle, slf4j and termlib are kept whole because they find algorithms and callbacks by name). The signed release APK (17.9 MB, v2 signature) was installed on the Pixel and checked against hetzner: first run, add server with Tailscale SSH and the host-key prompt (fingerprint matched the probe's), Overview, Docker with site icons, and the terminal (login banner) all work under R8. Local signing caught that a PKCS12 keystore needs the key password to equal the store password. CI job `android-release` (tag `android-v*`) mirrors the Mac's. Not yet tried: the CI job itself (first tag), updating over an installed release, and the other screens under R8 (editor, Updates, Add container).

## UX review changes (13 Oct 2026)

From a design and usability review of the 0.1.0-alpha.1 screenshots (items 8 to 15 of its spec plus the More, switcher and smaller items). Safety items 1 to 7 are separate and not done here.

- **Colour roles (UX1):** `AppPalette` (Swift and Kotlin, additive, Mac colours unchanged) gains `textDim`, status families (`okRole`, `warnRole`, `dangerRole`), `info`, three scope families and six `series` colours; each role has `mark` (3:1, dots and bars), `label` (4.5:1, words), `fill` and `onFill`. A test over all 45 themes checks every pair and that the series colours differ. The Android UI no longer contains a hard-coded colour: Tailscale is the magenta role (not green), container names and letter tiles come from the series, log levels from the status roles.
- **Chrome (UX2):** the Read-only chip keeps one width and label (closed lock filled, open lock outlined), asks once before allowing changes, and can switch itself back on (Safety page: start in Read-only, never / 5 or 15 minutes idle / when the app is backgrounded; default 15 minutes; never while an action runs; a snackbar says so). Server switcher: a status word next to every dot, a check for the current server, a per-row menu (Connect, Edit, Remove). Only the selected server has a live connection, so the others read "Not connected". More is grouped (SERVER, SERVERS, APP) with Terminal, Safety and About pages, and the tab gets an amber dot when security updates or a reboot need attention.
- **Stack page (UX3, UX4):** its own app bar (name and status, server, Read-only chip, menu), the header scrolls away and the tabs pin, the menu has subtitles and Edit bookmark, only Delete is red. Logs: two control rows, search in an icon, full screen, compact density, Debug chip, level chips that add up (unrecognised lines count as Info). Container cards: neutral action buttons, image tags never cut, ports on the status line. Docker list: the name has the whole header, the file name only when unusual, unhealthy rows say so, the summary adds up.
- **Overview (UX5):** one attention card (red before amber), equal-height stat cards, "Measuring…" while CPU needs a second sample, bars that warn at 85% and fail at 95%, copy on every System row.
- **Updates, Add container, Terminal, Appearance (UX6):** the apt button is "Update package lists" with a caption (the reload icon stays: it reads, the button changes the server), a neutral reboot card, labelled add-container fields with "Required" hints and removable rows, terminal keys with `| ~ / -` first and a compact arrow cluster, themes grouped by family.
- **Deliberately different from the review:** the stack menu keeps the Mac's verbs (Pull, Update, Restart all, Rebuild, Recreate, Delete) rather than merging Pull into Update; the port protocol dropdown is deferred (the shared form model only knows tcp); the Docker card bookmark icon stays on cards with no link (cards with a link edit it from the stack menu).
- Checked on the demo emulator in Dark and Light and on the Pixel earlier stages; the real phone has not been run on UX2 to UX6 yet.
