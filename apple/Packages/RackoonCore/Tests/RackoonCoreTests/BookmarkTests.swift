import Foundation
import XCTest
@testable import RackoonCore

final class BookmarkTests: XCTestCase {
    func testReadsHomepageLabels() throws {
        let labels = DockerParser.parseLabels("homepage.group=Media,homepage.name=AIOStreams,homepage.icon=aiostreams.png,homepage.href=https://aiostreams.xrray.net/,homepage.description=Stream aggregator, with commas,com.docker.compose.project=x")
        let b = try XCTUnwrap(Bookmark.from(labels: labels))
        XCTAssertEqual(b, Bookmark(href: "https://aiostreams.xrray.net/", name: "AIOStreams", group: "Media", icon: "aiostreams.png",
                                   description: "Stream aggregator, with commas"))
    }

    func testOnlyAUsableHrefMakesABookmark() {
        XCTAssertNil(Bookmark.from(labels: ["homepage.name": "x"]))
        for bad in ["", "ftp://x.com", "javascript:alert(1)", "https://", "not a url", "https://a b.com", "file:///etc/passwd", "x.com"] {
            XCTAssertNil(Bookmark.from(labels: ["homepage.href": bad]), bad)
        }
        for good in ["http://dockge", "https://x.example.com/path?a=1#b", "http://100.64.0.1:8080"] {
            XCTAssertNotNil(Bookmark.from(labels: ["homepage.href": good]), good)
        }
        XCTAssertNil(Bookmark.from(labels: ["homepage.href": "https://x.com", "homepage.name": "  "])?.name, "blank fields are absent")
    }

    func testParserPutsTheBookmarkOnTheContainerAndStack() throws {
        let row = #"{"ID":"39a63766f536","Names":"a-web-1","Image":"nginx","State":"running","Status":"Up","Labels":"com.docker.compose.project=a,com.docker.compose.service=web,com.docker.compose.project.working_dir=/opt/stacks/a,com.docker.compose.project.config_files=/opt/stacks/a/compose.yaml,homepage.href=https://a.example.com/,homepage.name=A"}"#
        let other = #"{"ID":"39a63766f537","Names":"a-db-1","Image":"pg","State":"running","Status":"Up","Labels":"com.docker.compose.project=a,com.docker.compose.service=db,com.docker.compose.project.working_dir=/opt/stacks/a,com.docker.compose.project.config_files=/opt/stacks/a/compose.yaml"}"#
        let snapshot = try DockerParser.parse("##docker\nok\n##ps\n\(row)\n\(other)\n##stats\n")
        let stack = try XCTUnwrap(snapshot.stacks.first)
        XCTAssertTrue(stack.hasBookmark)
        XCTAssertEqual(stack.containers.first { $0.service == "web" }?.bookmark?.href, "https://a.example.com/")
        XCTAssertNil(stack.containers.first { $0.service == "db" }?.bookmark)
    }

    func testOldSnapshotsWithoutBookmarksStillDecode() throws {
        let c = DockerContainer(id: "abcdef012345", name: "n", image: "i", state: "running", health: "none", status: "Up", ports: [])
        let data = try JSONEncoder().encode(c)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("bookmark"))
        XCTAssertEqual(try JSONDecoder().decode(DockerContainer.self, from: data), c)
    }

    func testLabelChangesDropEmptyFields() {
        let changes = Bookmark(href: " https://x.com ", name: "X", group: "", icon: nil, description: "  ").labelChanges
        XCTAssertEqual(changes.map(\.key), Bookmark.labelKeys)
        XCTAssertEqual(changes.map(\.value), [nil, "X", nil, "https://x.com", nil])
        XCTAssertTrue(Bookmark.removalChanges.allSatisfy { $0.value == nil })
    }
}

final class ComposeLabelsTests: XCTestCase {
    private let bookmark = Bookmark(href: "https://aiostreams.xrray.net/", name: "AIOStreams", group: "Media")

    private func set(_ b: Bookmark?, _ text: String, service: String = "web") throws -> String {
        try ComposeLabels.setting(b?.labelChanges ?? Bookmark.removalChanges, onService: service, in: text)
    }

    func testAddsALabelsBlockToAServiceWithNone() throws {
        let file = "# keep me\nservices:\n  web:\n    image: nginx\n    ports:\n      - \"80:80\"\n  db:\n    image: pg\n"
        XCTAssertEqual(try set(bookmark, file), """
        # keep me
        services:
          web:
            image: nginx
            ports:
              - "80:80"
            labels:
              - homepage.group=Media
              - homepage.name=AIOStreams
              - homepage.href=https://aiostreams.xrray.net/
          db:
            image: pg

        """)
    }

    func testReplacesAddsAndKeepsOtherLabelsInAListBlock() throws {
        let file = """
        services:
          web:
            image: nginx
            labels:
              - traefik.enable=true
              - homepage.href=http://old
              - "homepage.name=Old"
              - homepage.weight=5
            restart: always

        """
        XCTAssertEqual(try set(bookmark, file), """
        services:
          web:
            image: nginx
            labels:
              - traefik.enable=true
              - homepage.href=https://aiostreams.xrray.net/
              - homepage.name=AIOStreams
              - homepage.weight=5
              - homepage.group=Media
            restart: always

        """)
    }

    func testMapStyleLabels() throws {
        let file = "services:\n  web:\n    image: nginx\n    labels:\n      traefik.enable: \"true\"\n      homepage.href: http://old\n"
        XCTAssertEqual(try set(bookmark, file), "services:\n  web:\n    image: nginx\n    labels:\n      traefik.enable: \"true\"\n      homepage.href: https://aiostreams.xrray.net/\n      homepage.group: Media\n      homepage.name: AIOStreams\n")
    }

    func testRemovingTheBookmarkKeepsOtherLabelsOrDropsAnEmptyBlock() throws {
        let withOther = "services:\n  web:\n    image: nginx\n    labels:\n      - traefik.enable=true\n      - homepage.href=http://x\n      - homepage.name=X\n"
        XCTAssertEqual(try set(nil, withOther), "services:\n  web:\n    image: nginx\n    labels:\n      - traefik.enable=true\n")
        let only = "services:\n  web:\n    image: nginx\n    labels:\n      - homepage.href=http://x\n    restart: always\n"
        XCTAssertEqual(try set(nil, only), "services:\n  web:\n    image: nginx\n    restart: always\n")
        let none = "services:\n  web:\n    image: nginx\n"
        XCTAssertEqual(try set(nil, none), none, "nothing to remove: unchanged")
    }

    func testFollowsTheFilesIndentationAndTargetsTheRightService() throws {
        let file = "services:\n    db:\n        image: pg\n    web:\n        image: nginx\n"
        let out = try set(Bookmark(href: "http://web"), file)
        XCTAssertEqual(out, "services:\n    db:\n        image: pg\n    web:\n        image: nginx\n        labels:\n            - homepage.href=http://web\n")
        XCTAssertEqual(try set(Bookmark(href: "http://db"), file, service: "db"),
                       "services:\n    db:\n        image: pg\n        labels:\n            - homepage.href=http://db\n    web:\n        image: nginx\n")
    }

    func testRefusesWhatItCannotEditSafely() {
        func fails(_ text: String, _ expected: ComposeLabelsError, service: String = "web", line: UInt = #line) {
            XCTAssertThrowsError(try ComposeLabels.setting(bookmark.labelChanges, onService: service, in: text), line: line) {
                XCTAssertEqual($0 as? ComposeLabelsError, expected, line: line)
            }
        }
        fails("services:\n  web:\n    image: x\n", .serviceNotFound("nope"), service: "nope")
        fails("services: {}\n", .inlineServices)
        fails("volumes:\n  d: {}\n", .serviceNotFound("web"))
        fails("services:\n  web:\n    image: x\n    labels: {a: b}\n", .flowLabels("web"))
        fails("services:\n  web:\n    <<: *base\n    image: x\n", .mergeKey("web"))
    }

    func testQuotingAndDollarSigns() throws {
        let b = Bookmark(href: "https://x.com/?a=1", name: "Plex: Media", description: "50% off #1 $HOME")
        let out = try set(b, "services:\n  web:\n    image: x\n")
        XCTAssertTrue(out.contains("- \"homepage.name=Plex: Media\""), out)
        XCTAssertTrue(out.contains("- \"homepage.description=50% off #1 $$HOME\""), out)
        XCTAssertTrue(out.contains("- homepage.href=https://x.com/?a=1"), out)
    }

    func testListDashesAtTheSameIndentAsTheLabelsKey() throws {
        let file = "services:\n  web:\n    image: nginx\n    labels:\n    - traefik.enable=true\n    - homepage.href=http://old\n    restart: always\n"
        XCTAssertEqual(try set(Bookmark(href: "http://new", name: "N"), file),
                       "services:\n  web:\n    image: nginx\n    labels:\n    - traefik.enable=true\n    - homepage.href=http://new\n    - homepage.name=N\n    restart: always\n")
        XCTAssertEqual(try set(nil, file), "services:\n  web:\n    image: nginx\n    labels:\n    - traefik.enable=true\n    restart: always\n")
        let only = "services:\n  web:\n    image: nginx\n    labels:\n    - homepage.href=http://old\n    restart: always\n"
        XCTAssertEqual(try set(nil, only), "services:\n  web:\n    image: nginx\n    restart: always\n")
        // The block ends at the next sibling key, which is not a dash line.
        let last = "services:\n  web:\n    image: nginx\n    labels:\n    - a=b\n  db:\n    image: pg\n"
        XCTAssertEqual(try set(Bookmark(href: "http://x"), last), "services:\n  web:\n    image: nginx\n    labels:\n    - a=b\n    - homepage.href=http://x\n  db:\n    image: pg\n")
    }

    func testDefinesService() {
        let t = "services:\n  web:\n    image: x\n"
        XCTAssertTrue(ComposeLabels.definesService("web", in: t))
        XCTAssertFalse(ComposeLabels.definesService("db", in: t))
    }
}
