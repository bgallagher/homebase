import Foundation

/// The shell commands for reading, checking and saving a stack's files. Templates equal the scripts in
/// spec/commands.json (`file_read`, `file_validate`, `file_write`); a test enforces it.
///
/// Safety shape of a save: the new content is written to a temp file in the same folder, checked by the server's
/// own `docker compose config` (so the check sees the same relative paths), and only then moved over the original
/// atomically, after confirming the original still has the hash that was opened. The previous file is kept as
/// `<file>.rackoon.bak`, and owner and permissions are carried over.
public enum StackFileCommands {
    public static let readTemplate = #"F={file}; if [ ! -e "$F" ]; then echo '##missing'; exit 0; fi; if [ "$(stat -c %s "$F")" -gt 65536 ]; then echo '##toolarge'; exit 0; fi; echo '##meta'; stat -c '%Y %a %U:%G' "$F"; echo '##sha256'; sha256sum "$F" | cut -d' ' -f1; echo '##content'; base64 -w0 "$F"; echo"#

    public static let validateTemplate = #"D={dir}; T=$(mktemp "$D/.rackoon-check.XXXXXX") || { echo '##cannot-write'; exit 7; }; trap 'rm -f "$T"' EXIT; echo {b64} | base64 -d > "$T"; docker compose -p {project} --project-directory "$D" {args} config -q 2>&1"#

    public static let writeTemplate = #"F={file}; D={dir}; {expect}; T=$(mktemp "$D/.rackoon-save.XXXXXX") || { echo '##cannot-write'; exit 7; }; trap 'rm -f "$T"' EXIT; echo {b64} | base64 -d > "$T"; if ! OUT=$(docker compose -p {project} --project-directory "$D" {args} config -q 2>&1); then echo '##invalid'; echo "$OUT"; exit 4; fi; if [ -e "$F" ]; then chmod --reference="$F" "$T"; chown --reference="$F" "$T" 2>/dev/null; cp -p "$F" "$F.rackoon.bak" || { echo '##cannot-write'; exit 7; }; else chmod 600 "$T"; fi; mv -f "$T" "$F"; echo '##saved'; sha256sum "$F" | cut -d' ' -f1"#

    static let expectExisting = #"[ "$(sha256sum "$F" | cut -d' ' -f1)" = {sha} ] || { echo '##changed'; exit 3; }"#
    static let expectNone = #"[ ! -e "$F" ] || { echo '##changed'; exit 3; }"#

    /// Reads one file. Nil if the file is not one the stack offers.
    public static func read(_ file: EditableFile, in stack: DockerStack) -> String? {
        guard StackFiles.editable(for: stack)?.contains(file) == true, let path = ShellQuote.quotePath(file.path) else { return nil }
        return Template.fill(readTemplate, ["file": path])
    }

    /// Checks `content` as the new version of `file` using the server's `docker compose config`, changing nothing.
    public static func validate(_ file: EditableFile, content: String, in stack: DockerStack) -> String? {
        guard let parts = common(file, content: content, in: stack) else { return nil }
        return Template.fill(validateTemplate, ["dir": parts.dir, "b64": parts.b64, "project": stack.name, "args": parts.args])
    }

    /// Saves `content` over `file`. `expectedSHA` is the hash of the version that was opened (nil if the file did not exist).
    public static func write(_ file: EditableFile, content: String, expectedSHA: String?, in stack: DockerStack) -> String? {
        guard let parts = common(file, content: content, in: stack), let path = ShellQuote.quotePath(file.path) else { return nil }
        let expect: String
        if let sha = expectedSHA {
            guard sha.count == 64, sha.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
            expect = Template.fill(expectExisting, ["sha": "'\(sha)'"])
        } else {
            expect = expectNone
        }
        return Template.fill(writeTemplate, ["file": path, "dir": parts.dir, "b64": parts.b64, "project": stack.name,
                                             "args": parts.args, "expect": expect])
    }

    private static func common(_ file: EditableFile, content: String, in stack: DockerStack) -> (dir: String, b64: String, args: String)? {
        guard StackFiles.editable(for: stack)?.contains(file) == true,
              content.utf8.count <= StackFiles.maxBytes,
              let dir = stack.workingDir.flatMap(ShellQuote.quotePath),
              // An empty file encodes to an empty string, which `quote` refuses; it is just `''` here.
              let b64 = content.isEmpty ? "''" : ShellQuote.quote(Data(content.utf8).base64EncodedString()),
              let args = composeArguments(replacing: file, in: stack) else { return nil }
        return (dir, b64, args)
    }

    /// `-f` for every compose file, with the edited one swapped for the temp file (`"$T"`), or `--env-file "$T"` when
    /// `.env` is the file being edited. Everything else is quoted as in the compose actions.
    static func composeArguments(replacing file: EditableFile, in stack: DockerStack) -> String? {
        let paths = stack.configFiles.isEmpty ? (stack.configFile.map { [$0] } ?? []) : stack.configFiles
        var parts: [String] = []
        if file.isEnv { parts += ["--env-file", #""$T""#] }
        for path in paths {
            if file == .compose(path) {
                parts += ["-f", #""$T""#]
            } else {
                guard let quoted = ShellQuote.quotePath(path) else { return nil }
                parts += ["-f", quoted]
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
