import Foundation
import XCTest
@testable import RackoonCore

final class AppIconsTests: XCTestCase {
    /// A small slice of the real collection's names, including the awkward ones (dashes, variants, look-alikes).
    private let catalog = IconCatalog(names: [
        "jellyfin", "jellyfin-vue", "immich", "immich-frame", "nextcloud", "paperless-ngx", "paperless", "home-assistant",
        "adguard-home", "vaultwarden", "vaultwarden-light", "uptime-kuma", "grafana", "prometheus", "loki", "traefik", "watchtower",
        "dockge", "redis", "postgres", "postgresql", "mariadb", "portainer", "portainer-dark", "speedtest-tracker", "pi-hole",
        "homebridge", "sonarr", "radarr", "authentik", "mongodb", "cloudflare", "wireguard", "glances-light", "shlink",
    ])

    private func container(_ service: String?, _ image: String, name: String? = nil, bookmark: Bookmark? = nil) -> DockerContainer {
        DockerContainer(id: "abcdef012345", name: name ?? "x-\(service ?? "c")-1", image: image, state: "running", health: "none",
                        status: "Up", ports: [], project: service == nil ? nil : "x", service: service, bookmark: bookmark)
    }

    private func stack(_ name: String, _ containers: [DockerContainer], standalone: Bool = false) -> DockerStack {
        DockerStack(name: name, workingDir: nil, configFile: nil, configFiles: [], containers: containers, isStandalone: standalone)
    }

    func testTreeParsingKeepsOnlySafePNGNames() throws {
        let tree = #"{"png": ["jellyfin.png", "home-assistant.png", "../evil.png", "Bad Name.png", "x.svg"], "svg": ["a.svg"]}"#
        let parsed = try XCTUnwrap(IconCatalog.parseTree(Data(tree.utf8)))
        XCTAssertEqual(parsed.names, ["jellyfin", "home-assistant"])
        XCTAssertNil(IconCatalog.parseTree(Data("[]".utf8)))
        XCTAssertNil(IconCatalog.parseTree(Data(#"{"png": []}"#.utf8)))
    }

    func testLookupIgnoresDashesAndPrefersThePlainIcon() {
        XCTAssertEqual(catalog.lookup("homeassistant"), "home-assistant")
        XCTAssertEqual(catalog.lookup("pihole"), "pi-hole")
        XCTAssertEqual(catalog.lookup("vaultwarden"), "vaultwarden")
        XCTAssertEqual(catalog.lookup("glances"), "glances-light", "a variant is used when it is the only one")
        XCTAssertNil(catalog.lookup("nothing-like-this"))
    }

    func testImageGuesses() {
        let cases: [(String, String?)] = [
            ("jellyfin/jellyfin:10.10.3", "jellyfin"),
            ("ghcr.io/immich-app/immich-server:v1.122.0", "immich"),
            ("ghcr.io/immich-app/immich-machine-learning:v1.122.0", "immich"),
            ("vaultwarden/server:1.32.7", "vaultwarden"),
            ("ghcr.io/goauthentik/server:2024.12", "authentik"),   // "server" is a role word; the organisation has an alias
            ("lscr.io/linuxserver/sonarr:latest", "sonarr"),
            ("redis:7-alpine", "redis"),
            ("postgres:16", "postgres"),
            ("tensorchord/pgvecto-rs:pg14-v0.2.0", "postgresql"),
            ("mongo:7", "mongodb"),
            ("prom/node-exporter:latest", "prometheus"),
            ("grafana/promtail:3.3.0", "loki"),
            ("adguard/adguardhome:v0.107.55", "adguard-home"),
            ("pihole/pihole:2024.07.0", "pi-hole"),
            ("registry.local:5000/team/portainer@sha256:" + String(repeating: "a", count: 64), "portainer"),
            ("louislam/uptime-kuma:1", "uptime-kuma"),
            ("myorg/something-custom:2", nil),
        ]
        for (image, expected) in cases { XCTAssertEqual(AppIconGuess.forImage(image, in: catalog), expected, image) }
    }

    func testStackPrefersItsNameThenAppsOverInfrastructure() {
        let immich = stack("immich", [container("database", "tensorchord/pgvecto-rs:pg14"), container("redis", "redis:7"),
                                      container("immich-server", "ghcr.io/immich-app/immich-server:v1")])
        XCTAssertEqual(AppIconGuess.forStack(immich, in: catalog), "immich")
        let monitoring = stack("monitoring", [container("grafana", "grafana/grafana:11"), container("prometheus", "prom/prometheus:v2")])
        XCTAssertEqual(AppIconGuess.forStack(monitoring, in: catalog), "grafana", "first app in the stack's order")
        let thing = stack("thing", [container("db", "postgres:16"), container("cache", "redis:7"), container("web", "myorg/thing-web:1")])
        XCTAssertEqual(AppIconGuess.forStack(thing, in: catalog), "postgres", "infrastructure only when nothing else matches")
        let custom = stack("media", [container("db", "mariadb:11"), container("tv", "lscr.io/linuxserver/sonarr")])
        XCTAssertEqual(AppIconGuess.forStack(custom, in: catalog), "sonarr", "an app beats the database listed before it")
        XCTAssertNil(AppIconGuess.forStack(stack("mystery", [container("web", "myorg/mystery:1")]), in: catalog))
    }

    func testAHomepageIconLabelWins() {
        let b = Bookmark(href: "http://h:1/", icon: "Grafana.png")
        let s = stack("jellyfin", [container("jellyfin", "jellyfin/jellyfin", bookmark: b)])
        XCTAssertEqual(AppIconGuess.forStack(s, in: catalog), "grafana")
        let url = Bookmark(href: "http://h:1/", icon: "https://example.com/x.png")
        XCTAssertEqual(AppIconGuess.forStack(stack("jellyfin", [container("jellyfin", "jellyfin/jellyfin", bookmark: url)]), in: catalog),
                       "jellyfin", "a URL or mdi- icon is not a catalog name")
    }

    func testStandaloneContainerNamesWithReplicaNumbers() {
        let s = stack("speedtest-tracker-2", [container(nil, "lscr.io/linuxserver/speedtest-tracker:0.24", name: "speedtest-tracker-2")], standalone: true)
        XCTAssertEqual(AppIconGuess.forStack(s, in: catalog), "speedtest-tracker")
    }

    func testServicesOfTheAppItselfHaveNoIconOfTheirOwn() {
        XCTAssertNil(AppIconGuess.forService(container("worker", "myorg/thing-worker:1"), in: catalog))
        XCTAssertEqual(AppIconGuess.forService(container("redis", "redis:7"), in: catalog), "redis")
    }

    func testSearch() {
        XCTAssertEqual(catalog.search("jelly"), ["jellyfin", "jellyfin-vue"])
        XCTAssertEqual(catalog.search("home assistant"), ["home-assistant"])
        XCTAssertEqual(catalog.search("portainer"), ["portainer"], "variants only when asked")
        XCTAssertEqual(catalog.search("portainer dark"), ["portainer-dark"])
        XCTAssertEqual(catalog.search("  "), [])
        XCTAssertEqual(catalog.search("e", limit: 3).count, 3)
    }
}

final class IconSourcesTests: XCTestCase {
    private let catalog = IconCatalog(
        names: ["jellyfin", "deluge", "plex", "sabnzbd", "prowlarr", "postgresql", "redis", "nextcloud", "arch-linux", "arch", "home-assistant"],
        selfhst: ["jellyfin", "2fauth", "home-assistant", "homeassistant", "super-productivity", "bad name", "convertx"])

    private func container(_ image: String, icon: String? = nil, name: String = "c") -> DockerContainer {
        DockerContainer(id: "abcdef012345", name: name, image: image, state: "running", health: "none", status: "Up", ports: [],
                        iconURL: icon)
    }

    func testSelfhstOnlyFillsGaps() {
        XCTAssertTrue(catalog.names.contains("sh:2fauth"))
        XCTAssertTrue(catalog.names.contains("sh:super-productivity"))
        XCTAssertFalse(catalog.names.contains("sh:jellyfin"), "dashboard-icons already has it")
        XCTAssertFalse(catalog.names.contains("sh:homeassistant"), "same app as home-assistant, dashes ignored")
        XCTAssertFalse(catalog.names.contains { $0.contains(" ") })
        XCTAssertEqual(catalog.lookup("2fauth"), "sh:2fauth")
        XCTAssertEqual(catalog.lookup("superproductivity"), "sh:super-productivity")
        XCTAssertEqual(catalog.lookup("jellyfin"), "jellyfin")
        XCTAssertEqual(catalog.search("super"), ["sh:super-productivity"])
        XCTAssertEqual(catalog.search("conv"), ["sh:convertx"])
    }

    func testSelfhstIndexParsing() {
        let index = #"[{"Name":"2FAuth","Reference":"2fauth","PNG":"Yes"},{"Reference":"svg-only","PNG":"No"},{"Reference":"../x","PNG":"Yes"}]"#
        XCTAssertEqual(IconCatalog.parseSelfhstIndex(Data(index.utf8)), ["2fauth"])
        XCTAssertNil(IconCatalog.parseSelfhstIndex(Data("{}".utf8)))
    }

    func testIconRefRoundTripsAndRejectsJunk() {
        for id in ["jellyfin", "sh:2fauth", "custom:0123456789abcdef", "url:https://example.com/a.png"] {
            XCTAssertEqual(AppIconRef(id: id)?.id, id)
        }
        XCTAssertEqual(AppIconRef(id: "sh:2fauth")?.downloadURL, "\(AppIconRef.selfhstCDN)/png/2fauth.png")
        XCTAssertEqual(AppIconRef(id: "jellyfin")?.downloadURL, "\(AppIconRef.dashboardCDN)/png/jellyfin.png")
        XCTAssertNil(AppIconRef(id: "custom:0123")?.downloadURL)
        XCTAssertNil(AppIconRef(id: "custom:../../etc"))
        XCTAssertNil(AppIconRef(id: "custom:0123456789ABCDEF"), "lowercase hex only")
        XCTAssertNil(AppIconRef(id: "sh:../x"))
        XCTAssertNil(AppIconRef(id: "url:file:///etc/passwd"))
        XCTAssertNil(AppIconRef(id: "url:javascript:alert(1)"))
        XCTAssertNil(AppIconRef(id: "Bad Name"))
        XCTAssertFalse(AppIconRef.remote("https://x.y/i.png").isChoosable)
    }

    func testBinhexAndBundledImages() {
        XCTAssertEqual(AppIconGuess.forImage("binhex/arch-delugevpn", in: catalog), "deluge", "not the Arch Linux logo")
        XCTAssertEqual(AppIconGuess.forImage("ghcr.io/binhex/arch-plexpass", in: catalog), "plex")
        XCTAssertEqual(AppIconGuess.forImage("binhex/arch-sabnzbdvpn", in: catalog), "sabnzbd")
        XCTAssertEqual(AppIconGuess.forImage("binhex/arch-prowlarr", in: catalog), "prowlarr")
        XCTAssertEqual(AppIconGuess.forImage("ghcr.io/nextcloud-releases/aio-postgresql:beta", in: catalog), "postgresql")
        XCTAssertEqual(AppIconGuess.forImage("ghcr.io/nextcloud-releases/aio-talk:beta", in: catalog), "nextcloud", "falls back to the organisation")
        XCTAssertEqual(AppIconGuess.forImage("nextcloud/all-in-one:beta", in: catalog), "nextcloud")
        XCTAssertEqual(AppIconGuess.forImage("johannesjo/super-productivity:latest", in: catalog), "sh:super-productivity")
    }

    func testUnraidTemplateIconWinsOverTheGuessButNotAHomepageLabel() {
        let url = "https://raw.githubusercontent.com/binhex/docker-templates/master/binhex/images/deluge-icon.png"
        let delugeC = container("binhex/arch-delugevpn", icon: url, name: "binhex-delugevpn")
        let stack = DockerStack(name: "binhex-delugevpn", workingDir: nil, configFile: nil, configFiles: [], containers: [delugeC], isStandalone: true)
        XCTAssertEqual(AppIconGuess.iconID(for: stack, in: catalog), "url:" + url)
        XCTAssertEqual(AppIconGuess.iconID(for: stack, in: nil), "url:" + url, "works before the catalog has loaded")
        XCTAssertEqual(AppIconGuess.iconID(for: delugeC, in: catalog), "url:" + url)
        XCTAssertEqual(AppIconGuess.iconID(for: container("redis:7"), in: catalog), "redis")

        var labelled = delugeC
        labelled.bookmark = Bookmark(href: "http://nas:8112", icon: "plex.png")
        let withLabel = DockerStack(name: "d", workingDir: nil, configFile: nil, configFiles: [], containers: [labelled], isStandalone: true)
        XCTAssertEqual(AppIconGuess.iconID(for: withLabel, in: catalog), "plex", "an explicit homepage.icon label still wins")
    }

    func testComposeStackTakesTheTemplateIconOfWhicheverContainerHasOne() {
        let url = "https://raw.githubusercontent.com/x/nextcloud_aio.png"
        var master = container("nextcloud/all-in-one:beta", icon: url, name: "nextcloud-aio-mastercontainer")
        master.project = "nextcloud-aio"
        var redis = container("ghcr.io/nextcloud-releases/aio-redis:beta", name: "nextcloud-aio-redis")
        redis.project = "nextcloud-aio"
        let stack = DockerStack(name: "nextcloud-aio", workingDir: nil, configFile: nil, configFiles: [],
                                containers: [redis, master], isStandalone: false)
        XCTAssertEqual(AppIconGuess.iconID(for: stack, in: catalog), "url:" + url)
        XCTAssertEqual(AppIconGuess.iconID(for: redis, in: catalog), "redis", "a service without a template icon keeps its guess")
        var bare = stack
        bare.containers = [redis]
        XCTAssertEqual(AppIconGuess.iconID(for: bare, in: catalog), "nextcloud", "no template icon at all: the guess from the name")
    }

    func testDockerParserKeepsOnlyWebIconLabels() throws {
        func row(_ label: String) -> String {
            #"{"ID":"abcdef012345","Names":"x","Image":"i","State":"running","Status":"Up","Labels":"net.unraid.docker.icon=\#(label)"}"#
        }
        for (label, expected) in [("https://a.b/x.png", "https://a.b/x.png"), ("file:///mnt/user/a.png", nil), ("", nil)] as [(String, String?)] {
            let snapshot = try DockerParser.parse("##docker\nok\n##ps\n\(row(label))\n##stats\n")
            XCTAssertEqual(snapshot.containers.first?.iconURL, expected, label)
        }
    }
}

final class IconChoicesTests: XCTestCase {
    private let catalog = IconCatalog(names: ["immich", "postgres", "redis", "deluge", "portainer"])
    private let server = "srv"
    private let url = "https://example.com/deluge.png"

    private func container(_ name: String, _ image: String, service: String? = nil, icon: String? = nil) -> DockerContainer {
        DockerContainer(id: "abcdef012345", name: name, image: image, state: "running", health: "none", status: "Up", ports: [],
                        project: service == nil ? nil : "p", service: service, iconURL: icon)
    }

    private var immich: DockerStack {
        DockerStack(name: "immich", workingDir: "/opt/immich", configFile: nil, configFiles: [], containers: [
            container("immich_server", "ghcr.io/immich-app/immich-server", service: "immich-server"),
            container("immich_postgres", "postgres:16", service: "database"),
            container("immich_redis", "redis:7", service: "redis"),
        ], isStandalone: false)
    }

    private var deluge: DockerStack {
        DockerStack(name: "binhex-delugevpn", workingDir: nil, configFile: nil, configFiles: [],
                    containers: [container("binhex-delugevpn", "binhex/arch-delugevpn", icon: url)], isStandalone: true)
    }

    func testLoadingDropsJunkAndLinkedIcons() {
        let choices = IconChoices(["a|b": "immich", "a|c": "", "a|d": "../x", "a|e": "url:https://x.y/i.png", "a|f": "custom:0123456789abcdef",
                                   "a|g": "sh:2fauth", "a|h": "custom:nothex!"])
        XCTAssertEqual(Set(choices.overrides.keys), ["a|b", "a|c", "a|f", "a|g"])
    }

    func testChooseAndRevert() {
        var choices = IconChoices()
        XCTAssertEqual(choices.stackIcon(immich, server: server, catalog: catalog), "immich", "automatic")
        XCTAssertTrue(choices.choose("redis", for: immich, server: server))
        XCTAssertEqual(choices.stackIcon(immich, server: server, catalog: catalog), "redis")
        XCTAssertTrue(choices.isChosen(immich, server: server))
        XCTAssertFalse(choices.choose("url:https://x.y/i.png", for: immich, server: server), "a linked icon is never saved")
        XCTAssertFalse(choices.choose("../etc", for: immich, server: server))
        XCTAssertEqual(choices.stackIcon(immich, server: server, catalog: catalog), "redis", "a refused choice changes nothing")
        choices.choose(nil, for: immich, server: server)
        XCTAssertFalse(choices.isChosen(immich, server: server))
        XCTAssertEqual(choices.stackIcon(immich, server: server, catalog: catalog), "immich")
        XCTAssertEqual(choices.stackIcon(immich, server: "other", catalog: catalog), "immich", "choices are per server")
    }

    func testLetterAndAppsIcon() {
        var choices = IconChoices()
        choices.choose("", for: immich, server: server)
        XCTAssertTrue(choices.prefersLetter(immich, server: server))
        XCTAssertNil(choices.stackIcon(immich, server: server, catalog: catalog))
        let redis = immich.containers[2]
        XCTAssertEqual(choices.serviceIcon(redis, in: immich, server: server, catalog: catalog), "redis")
        choices.choose("", for: immich, service: redis, server: server)
        XCTAssertNil(choices.serviceIcon(redis, in: immich, server: server, catalog: catalog), "\"\" = draw it with the app's icon")
        XCTAssertTrue(choices.isChosen(immich, service: redis, server: server))
    }

    func testTheMainServiceFollowsTheAppsChoice() {
        var choices = IconChoices()
        let server0 = immich.containers[0], db = immich.containers[1]
        XCTAssertTrue(IconChoices.isMainService(server0, of: immich, in: catalog), "its automatic icon is the app's")
        XCTAssertFalse(IconChoices.isMainService(db, of: immich, in: catalog))
        choices.choose("sh:2fauth", for: immich, server: server)
        XCTAssertNil(choices.serviceIcon(server0, in: immich, server: server, catalog: catalog), "follows the app")
        XCTAssertEqual(choices.serviceIcon(db, in: immich, server: server, catalog: catalog), "postgres", "keeps its own")
        choices.choose("redis", for: immich, service: server0, server: server)
        XCTAssertEqual(choices.serviceIcon(server0, in: immich, server: server, catalog: catalog), "redis", "its own choice wins")

        // A standalone container IS the app, even though its template icon differs from any guess.
        let only = deluge.containers[0]
        XCTAssertTrue(IconChoices.isMainService(only, of: deluge, in: catalog))
        XCTAssertEqual(choices.serviceIcon(only, in: deluge, server: server, catalog: catalog), "url:" + url)
        choices.choose("portainer", for: deluge, server: server)
        XCTAssertNil(choices.serviceIcon(only, in: deluge, server: server, catalog: catalog))
        XCTAssertEqual(choices.stackIcon(deluge, server: server, catalog: catalog), "portainer")
    }

    func testOneServiceComposeStackIsItsOwnMainService() {
        let one = DockerStack(name: "app", workingDir: "/x", configFile: nil, configFiles: [],
                              containers: [container("app-web-1", "nginx", service: "web")], isStandalone: false)
        XCTAssertTrue(IconChoices.isMainService(one.containers[0], of: one, in: nil))
        let nothing = immich.containers.map { container($0.name, "unknown/thing", service: $0.service) }
        let unknown = DockerStack(name: "zzz", workingDir: nil, configFile: nil, configFiles: [], containers: nothing, isStandalone: false)
        XCTAssertFalse(IconChoices.isMainService(unknown.containers[0], of: unknown, in: catalog),
                       "no automatic icon on either side is not a match")
    }

    func testDeadTemplateURLFallsBackToTheGuess() {
        let choices = IconChoices()
        let id = "url:" + url
        XCTAssertEqual(choices.stackIcon(deluge, server: server, catalog: catalog), id)
        XCTAssertEqual(choices.stackIcon(deluge, server: server, catalog: catalog, failed: { $0 == id }), "deluge")
        XCTAssertEqual(choices.serviceIcon(deluge.containers[0], in: deluge, server: server, catalog: catalog, failed: { $0 == id }), "deluge")
        XCTAssertNil(choices.stackIcon(deluge, server: server, catalog: nil, failed: { $0 == id }), "no catalog yet: nothing to fall back to")
        XCTAssertEqual(choices.stackIcon(immich, server: server, catalog: catalog, failed: { _ in true }), "immich",
                       "a failed collection icon is not replaced (it is retried later)")
    }

    func testForgetAndRemoveUses() {
        var choices = IconChoices(["srv|immich": "custom:0123456789abcdef", "srv|immich|redis": "custom:0123456789abcdef",
                                   "srv2|x": "custom:0123456789abcdef", "srvX|y": "redis"])
        XCTAssertTrue(choices.forget(serverID: "srv"))
        XCTAssertEqual(Set(choices.overrides.keys), ["srv2|x", "srvX|y"], "srv2 and srvX are other servers, not prefixes of srv's keys")
        XCTAssertFalse(choices.forget(serverID: "srv"))
        XCTAssertTrue(choices.removeUses(of: "custom:0123456789abcdef"))
        XCTAssertEqual(choices.overrides, ["srvX|y": "redis"])
        XCTAssertFalse(choices.removeUses(of: "custom:0123456789abcdef"))
    }
}

final class IconFetchQueueTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testOrderUrgentFirstAndOnce() {
        var q = IconFetchQueue()
        q.request(["a", "b", "c"], now: t0) { _ in false }
        q.request(["d"], urgent: true, now: t0) { _ in false }
        q.request(["c"], urgent: true, now: t0) { _ in false }
        XCTAssertEqual(q.waiting, ["c", "d", "a", "b"], "the newest urgent request goes first, and c is not queued twice")
        XCTAssertEqual(q.next(), "c")
        q.request(["c"], urgent: true, now: t0) { _ in false }
        XCTAssertEqual(q.waiting, ["d", "a", "b"], "a download in progress is not queued again")
        XCTAssertTrue(q.fetching.contains("c"))
    }

    func testSkipsWhatIsHeldOrCannotBeDownloaded() {
        var q = IconFetchQueue()
        q.request(["have", "custom:0123456789abcdef", "Bad Name", "url:file:///etc/passwd", "sh:ok", "url:https://x.y/i.png"],
                  now: t0) { $0 == "have" }
        XCTAssertEqual(q.waiting, ["sh:ok", "url:https://x.y/i.png"])
    }

    func testFailureIsRetriedOnlyAfterADay() {
        var q = IconFetchQueue()
        q.request(["a"], now: t0) { _ in false }
        XCTAssertEqual(q.next(), "a")
        q.finish("a", success: false, now: t0)
        XCTAssertTrue(q.hasFailed("a"))
        XCTAssertTrue(q.fetching.isEmpty)
        q.request(["a"], urgent: true, now: t0.addingTimeInterval(3600)) { _ in false }
        XCTAssertTrue(q.waiting.isEmpty, "not asked again within a day")
        q.request(["a"], now: t0.addingTimeInterval(IconFetchQueue.retryAfter + 1)) { _ in false }
        XCTAssertEqual(q.waiting, ["a"])
        _ = q.next()
        q.finish("a", success: true, now: t0)
        XCTAssertFalse(q.hasFailed("a"), "a success clears the failure")
        XCTAssertNil(q.next())
    }
}
