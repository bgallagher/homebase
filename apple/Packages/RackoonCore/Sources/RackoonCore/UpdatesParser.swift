import Foundation

/// Pure parser for the `updates` command output (sections `##apt`, `##upgradable`, `##held`, `##refreshed`, `##reboot`).
public enum UpdatesParser {
    public static func parse(_ output: String) throws -> UpdatesSnapshot {
        let sections = OverviewParser.splitSections(output)
        guard let status = sections["apt"]?.first else { throw UpdatesParseError.malformed("no ##apt section") }
        if status == "missing" { throw UpdatesParseError.notInstalled }

        let packages = (sections["upgradable"] ?? []).compactMap(parseLine)
        let held = sections["held"] ?? []
        let refreshed = sections["refreshed"]?.first.flatMap { Int64($0) }
        return UpdatesSnapshot(
            packages: packages, held: held, refreshedAt: refreshed,
            rebootRequired: sections["reboot"]?.first == "yes")
    }

    /// `name/suite[,suite] new-version arch [upgradable from: old-version]`.
    /// Anything else ("Listing...", warnings) is not a package line and is skipped.
    static func parseLine(_ line: String) -> PendingUpdate? {
        let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard fields.count >= 3, let slash = fields[0].firstIndex(of: "/") else { return nil }
        let name = String(fields[0][..<slash])
        let suite = String(fields[0][fields[0].index(after: slash)...])
        guard !name.isEmpty, !suite.isEmpty else { return nil }

        var old: String?
        if fields.count == 4, let range = fields[3].range(of: "upgradable from: ") {
            let rest = fields[3][range.upperBound...]
            let value = rest.hasSuffix("]") ? rest.dropLast() : rest
            old = value.isEmpty ? nil : String(value)
        }
        let isSecurity = suite.split(separator: ",").contains { $0.hasSuffix("-security") }
        return PendingUpdate(name: name, suite: suite, newVersion: String(fields[1]), oldVersion: old,
                             architecture: String(fields[2]), isSecurity: isSecurity)
    }
}
