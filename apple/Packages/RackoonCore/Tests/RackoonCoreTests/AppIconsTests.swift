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
