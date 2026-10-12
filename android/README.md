# Rackoon for Android

Native Kotlin and Jetpack Compose, built in approved stages (see `docs/android-spikes.md` for the stack decision and the
spike results). **Stage A1 is done**: the portable core and its CI. The app, SSH module and terminal come next.

```
android/
  core/    pure Kotlin/JVM: a mirror of apple/Packages/RackoonCore (models, parsers, sessions, ActionPolicy, ShellQuote,
           log and stream helpers, command library, themes, output highlighter). No Android or SSH imports.
  ssh/     (A2) the sshj transport, host-key trust, key import
  app/     (A2+) Jetpack Compose UI, ConnectBot termlib terminal
  probe/   (A2+) a JVM CLI that runs the same real-server checks as rackoon-probe
```

## The contract

`spec/` is the source of truth, shared with the Swift core:

- `spec/fixtures/**` golden files: every Kotlin parser must produce exactly what the Swift one does (compared as JSON, numbers
  by value).
- `spec/commands.json` and `spec/command-library.json`: the shell commands. Unlike the Swift core, Kotlin keeps **no copy**:
  Gradle bundles these files into the module's resources and the code reads them (`SpecCommands`, `CommandLibrary`).
- `apple/Apps/RackoonMac/Resources/themes.json`: the 45 terminal themes, shared the same way (`ThemeCatalog.bundled()`).

## Commands

```
cd android
./gradlew :core:test        # 136 tests; needs JDK 21
```

CI runs the same (`android-core` job). Android Studio opens `android/` directly once the app module exists.

## Differences from the Swift core (on purpose)

- Sessions expose `StateFlow` instead of `AsyncStream`, and are driven by coroutines.
- `Confirmation` has a module-internal constructor: only `ActionPolicy.confirm` can make one from another module.
- A cancelled `StreamRunner.run` returns normally with `cancelled = true` (like the Swift one), so callers can still clean up.
- Not ported (Mac-only or later stages): `SSHConfig`, `ServerStore`, `LicenceKey`, favicon fetching, the compose/.env editor
  stack (`ComposeFormParser`, `ContainerSpec`, `NewStack`, `StackFiles*`, `EditorChecks`, `LineDiff`, `SyntaxHighlighter`),
  `RemoteFiles`, `StackRemoval`.
