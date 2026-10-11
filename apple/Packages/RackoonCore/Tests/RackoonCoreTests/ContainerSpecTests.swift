import Foundation
import XCTest
@testable import RackoonCore

final class ContainerSpecTests: XCTestCase {
    private func kuma() -> ContainerSpec {
        ContainerSpec(name: "uptime-kuma", image: "louislam/uptime-kuma:1",
                      ports: [PortRow(host: "3001", container: "3001"), PortRow()],
                      volumes: [VolumeRow(source: "./data", target: "/app/data")],
                      env: [EnvRow(key: "TZ", value: "Europe/Dublin")])
    }

    func testGeneratesTheComposeFromTheDesign() {
        XCTAssertEqual(kuma().composeText, """
        services:
          uptime-kuma:
            image: louislam/uptime-kuma:1
            restart: unless-stopped
            ports:
              - "3001:3001"
            volumes:
              - ./data:/app/data
            environment:
              TZ: ${TZ}

        """)
        XCTAssertEqual(kuma().envText, "TZ=Europe/Dublin\n")
        XCTAssertNil(kuma().blockingProblem)
    }

    func testBlankRowsAndEmptySectionsAreLeftOut() {
        let s = ContainerSpec(name: "web", image: "nginx:alpine", restart: .no)
        XCTAssertEqual(s.composeText, "services:\n  web:\n    image: nginx:alpine\n    restart: \"no\"\n")
        XCTAssertEqual(s.envText, "")
    }

    func testProblemsAreReportedPerField() {
        var s = kuma()
        s.name = "Bad Name!"; XCTAssertNotNil(s.nameProblem); XCTAssertNotNil(s.blockingProblem)
        s = kuma(); s.image = "nginx; reboot"; XCTAssertNotNil(s.imageProblem)
        s = kuma(); s.ports = [PortRow(host: "99999", container: "80")]; XCTAssertNotNil(s.blockingProblem)
        s = kuma(); s.ports = [PortRow(host: "80", container: "")]; XCTAssertNotNil(s.blockingProblem)
        s = kuma(); s.volumes = [VolumeRow(source: "data", target: "/x")]; XCTAssertNotNil(s.blockingProblem)
        s = kuma(); s.volumes = [VolumeRow(source: "./d", target: "rel")]; XCTAssertNotNil(s.blockingProblem)
        s = kuma(); s.env = [EnvRow(key: "1X", value: "a")]; XCTAssertNotNil(s.blockingProblem)
        s = kuma(); s.env = [EnvRow(key: "A", value: "1"), EnvRow(key: "A", value: "2")]; XCTAssertNotNil(s.blockingProblem)
        XCTAssertEqual(ContainerSpec().blockingProblem, "Enter a container name")
    }

    func testEnvLinesAreQuotedSafelyAndPassTheSyntaxCheck() {
        let s = ContainerSpec(name: "a", image: "a", env: [EnvRow(key: "PLAIN", value: "abc"), EnvRow(key: "SPACE", value: "a b"),
                                                          EnvRow(key: "DOLLAR", value: "p$ss#1"), EnvRow(key: "QUOTE", value: "it's"),
                                                          EnvRow(key: "EMPTY", value: "")])
        XCTAssertEqual(s.envText, "PLAIN=abc\nSPACE='a b'\nDOLLAR='p$ss#1'\nQUOTE=\"it's\"\nEMPTY=\n")
        XCTAssertTrue(EnvSyntax.check(s.envText).isEmpty)
    }

    func testEnvMergeKeepsWhatIsThere() {
        let existing = "# comment\nTZ=UTC\nexport KEEP=1"
        let merged = EnvMerge.merge(existing: existing, adding: [EnvRow(key: "TZ", value: "Europe/Dublin"), EnvRow(key: "NEW", value: "x")])
        XCTAssertEqual(merged.text, "# comment\nTZ=UTC\nexport KEEP=1\nNEW=x\n")
        XCTAssertEqual(merged.kept, ["TZ"])
        XCTAssertEqual(EnvMerge.merge(existing: "A=1\n", adding: [EnvRow(key: "A", value: "2")]).text, "A=1\n")
        XCTAssertEqual(EnvMerge.merge(existing: "", adding: [EnvRow(key: "A", value: "2")]).text, "A=2\n")
    }

    // MARK: adding to an existing compose file

    func testAddsAfterTheLastServiceAndLeavesTheRestAlone() throws {
        let file = """
        # my stack
        services:
          nginx:
            image: nginx:alpine
            ports:
              - "8085:80"

        volumes:
          data: {}

        """
        let result = try ComposeInsert.adding(kuma(), to: file)
        XCTAssertEqual(result, """
        # my stack
        services:
          nginx:
            image: nginx:alpine
            ports:
              - "8085:80"
          uptime-kuma:
            image: louislam/uptime-kuma:1
            restart: unless-stopped
            ports:
              - "3001:3001"
            volumes:
              - ./data:/app/data
            environment:
              TZ: ${TZ}

        volumes:
          data: {}

        """)
        XCTAssertEqual(ComposeInsert.services(in: result), ["nginx", "uptime-kuma"])
    }

    func testFollowsTheFilesIndentation() throws {
        let file = "services:\n    web:\n        image: nginx\n"
        let result = try ComposeInsert.adding(ContainerSpec(name: "db", image: "postgres:16"), to: file)
        XCTAssertEqual(result, "services:\n    web:\n        image: nginx\n    db:\n        image: postgres:16\n        restart: unless-stopped\n")
    }

    func testRefusesDuplicatesAndInlineServicesAndAddsMissingServicesKey() throws {
        XCTAssertThrowsError(try ComposeInsert.adding(ContainerSpec(name: "web", image: "x"), to: "services:\n  web:\n    image: a\n")) {
            XCTAssertEqual($0 as? ComposeInsertError, .serviceExists("web"))
        }
        XCTAssertThrowsError(try ComposeInsert.adding(ContainerSpec(name: "web", image: "x"), to: "services: {}\n")) {
            XCTAssertEqual($0 as? ComposeInsertError, .inlineServices)
        }
        let added = try ComposeInsert.adding(ContainerSpec(name: "web", image: "x"), to: "volumes:\n  d: {}\n")
        XCTAssertEqual(added, "volumes:\n  d: {}\n\nservices:\n  web:\n    image: x\n    restart: unless-stopped\n")
        // An empty `services:` takes the first service.
        XCTAssertEqual(try ComposeInsert.adding(ContainerSpec(name: "web", image: "x"), to: "services:\n"),
                       "services:\n  web:\n    image: x\n    restart: unless-stopped\n")
    }

    // MARK: checks

    func testSpecTemplatesAndFixture() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        func script(_ id: String) -> String? { commands.first { $0["id"] as? String == id }?["script"] as? String }
        XCTAssertEqual(ContainerChecks.imageTemplate, script("image_exists"))
        XCTAssertEqual(ContainerChecks.listeningPortsCommand, script("listening_ports"))
        let out = try String(contentsOf: specDir.appendingPathComponent("fixtures/listening_ports/basic.out.txt"), encoding: .utf8)
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: specDir.appendingPathComponent("fixtures/listening_ports/basic.expected.json"))) as! [String: [Int]]
        XCTAssertEqual(ContainerChecks.parseListeningPorts(out), Set(expected["ports"]!))
    }

    func testImageCommandIsValidatedAndQuoted() {
        XCTAssertEqual(ContainerChecks.imageCommand("nginx:alpine"),
                       "timeout 20 docker manifest inspect 'nginx:alpine' >/dev/null 2>&1; case $? in 0) echo found;; 124) echo timeout;; *) echo notfound;; esac")
        for bad in ["", "nginx; reboot", "a b", "$(id)", "-rm"] { XCTAssertNil(ContainerChecks.imageCommand(bad), bad) }
        XCTAssertEqual(ContainerChecks.parseImageStatus("found\n"), .found)
        XCTAssertEqual(ContainerChecks.parseImageStatus("timeout\n"), .timedOut)
        XCTAssertEqual(ContainerChecks.parseImageStatus("notfound\n"), .notFound)
        XCTAssertEqual(ContainerChecks.registryName("louislam/uptime-kuma:1"), "Docker Hub")
        XCTAssertEqual(ContainerChecks.registryName("ghcr.io/x/y:1"), "ghcr.io")
        XCTAssertEqual(ContainerChecks.registryName("localhost:5000/y"), "localhost:5000")
    }

    func testPortRowsNameTheOwnerAndSuggestAFreePort() {
        let owner = DockerContainer(id: "abcdef012345", name: "boycott-nginx-1", image: "nginx", state: "running", health: "none", status: "Up",
                                    ports: [.init(hostPort: 8085, containerPort: 80, proto: "tcp")], project: "boycottcadbury", service: "nginx")
        var s = kuma(); s.ports = [PortRow(host: "8085", container: "80"), PortRow(host: "3001", container: "3001")]
        let rows = ContainerChecks.portRows(s, listening: [22, 8085], containers: [owner], serverName: "hetzner")
        XCTAssertEqual(rows.map(\.state), [.fail, .pass])
        XCTAssertEqual(rows[0].title, "Port 8085 is already in use")
        XCTAssertEqual(rows[0].detail, "By nginx in boycottcadbury. Try 8086.")
        XCTAssertEqual(rows[1].detail, "Free on hetzner")
        XCTAssertEqual(ContainerChecks.portRows(s, listening: nil, containers: [], serverName: "h").map(\.state), [.running, .running])
        s.ports = [PortRow(host: "80", container: "80"), PortRow(host: "80", container: "81")]
        XCTAssertEqual(ContainerChecks.portRows(s, listening: [], containers: [], serverName: "h").map(\.state), [.fail])
    }

    func testNameRow() {
        let existing = DockerContainer(id: "abcdef012345", name: "media-uptime-kuma-1", image: "x", state: "running", health: "none", status: "Up",
                                       ports: [], project: "media", service: "uptime-kuma")
        XCTAssertEqual(ContainerChecks.nameRow(kuma(), stack: "media", containers: [existing]).state, .fail)
        XCTAssertEqual(ContainerChecks.nameRow(kuma(), stack: "other", containers: [existing]).state, .pass)
        XCTAssertEqual(ContainerChecks.nameRow(ContainerSpec(), stack: nil, containers: []).state, .skipped)
    }

    func testComposeRowCollapsesWhenAllPass() {
        let pass = (0..<3).map { EditorCheckRow(id: "\($0)", state: .pass, title: "t", detail: "") }
        XCTAssertEqual(ContainerChecks.composeRow(pass, serverName: "h").map(\.title), ["YAML syntax"])
        let failing = pass + [EditorCheckRow(id: "f", state: .fail, title: "docker compose config", detail: "bad")]
        XCTAssertEqual(ContainerChecks.composeRow(failing, serverName: "h").map(\.title), ["docker compose config"])
    }
}

final class ComposeFormParserTests: XCTestCase {
    func testReadsBackWhatTheFormWrites() throws {
        let spec = ContainerSpec(name: "uptime-kuma", image: "louislam/uptime-kuma:1",
                                 ports: [PortRow(host: "3001", container: "3001")], volumes: [VolumeRow(source: "./data", target: "/app/data")],
                                 env: [EnvRow(key: "TZ", value: "Europe/Dublin")], restart: .unlessStopped)
        let parsed = try XCTUnwrap(ComposeFormParser.parse(spec.composeText, env: spec.envText))
        XCTAssertEqual(parsed.spec, spec)
        XCTAssertTrue(parsed.lossless)
        for policy in RestartPolicy.allCases {
            var s = spec; s.restart = policy
            XCTAssertEqual(ComposeFormParser.parse(s.composeText, env: s.envText)?.spec.restart, policy)
        }
    }

    func testHelloWorldWithATailscaleBindAddress() throws {
        let text = "services:\n  hello:\n    image: nginxdemos/hello:latest\n    restart: unless-stopped\n    ports:\n      - \"${TS_IP}:8080:80\"\n"
        let parsed = try XCTUnwrap(ComposeFormParser.parse(text))
        XCTAssertTrue(parsed.lossless)
        XCTAssertEqual(parsed.spec.name, "hello")
        XCTAssertEqual(parsed.spec.image, "nginxdemos/hello:latest")
        XCTAssertEqual(parsed.spec.ports, [PortRow(host: "${TS_IP}:8080", container: "80")])
        XCTAssertEqual(parsed.spec.ports[0].hostPort, 8080)
        XCTAssertEqual(parsed.spec.ports[0].bindAddress, "${TS_IP}")
        XCTAssertNil(parsed.spec.blockingProblem)
        // And the form writes the same file back.
        XCTAssertEqual(parsed.spec.composeText, "services:\n  hello:\n    image: nginxdemos/hello:latest\n    restart: unless-stopped\n    ports:\n      - \"${TS_IP}:8080:80\"\n")
    }

    func testAnythingTheFormCannotShowMarksTheFileLossy() throws {
        let extras = ["    container_name: x\n", "    command: sleep 1\n", "    networks:\n      - a\n", "    labels:\n      a: b\n"]
        for extra in extras {
            let parsed = try XCTUnwrap(ComposeFormParser.parse("services:\n  web:\n    image: nginx\n" + extra))
            XCTAssertFalse(parsed.lossless, extra)
            XCTAssertEqual(parsed.spec.image, "nginx")
        }
        XCTAssertFalse(try XCTUnwrap(ComposeFormParser.parse("# note\nservices:\n  web:\n    image: nginx\n")).lossless)
        XCTAssertFalse(try XCTUnwrap(ComposeFormParser.parse("services:\n  web:\n    image: nginx\nvolumes:\n  d: {}\n")).lossless)
        XCTAssertFalse(try XCTUnwrap(ComposeFormParser.parse("services:\n  web:\n    image: nginx\n    environment:\n      A: literal\n")).lossless)
        XCTAssertFalse(try XCTUnwrap(ComposeFormParser.parse("services:\n  web:\n    image: nginx\n    ports:\n      - \"53:53/udp\"\n")).lossless)
    }

    func testNotAFormShapedFile() {
        XCTAssertNil(ComposeFormParser.parse(""))
        XCTAssertNil(ComposeFormParser.parse("services:\n"))
        XCTAssertNil(ComposeFormParser.parse("services:\n  a:\n    image: x\n  b:\n    image: y\n"))
        XCTAssertNil(ComposeFormParser.parse("volumes:\n  d: {}\n"))
    }

    func testBindAddressValidation() {
        XCTAssertNil(ContainerSpec.portProblem(PortRow(host: "127.0.0.1:8080", container: "80")))
        XCTAssertNil(ContainerSpec.portProblem(PortRow(host: "${TS_IP}:8080", container: "80")))
        XCTAssertNotNil(ContainerSpec.portProblem(PortRow(host: "evil;x:8080", container: "80")))
        XCTAssertNotNil(ContainerSpec.portProblem(PortRow(host: "1.2.3:8080", container: "80")))
    }
}

final class ComposeOverviewTests: XCTestCase {
    private let immich = """
    #
    # WARNING: To install Immich, follow our guide
    #
    name: immich

    services:
      immich-server:
        container_name: immich_server
        image: ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}
        # extends:
        #   file: hwaccel.transcoding.yml
        volumes:
          # Do not edit the next line.
          - ${UPLOAD_LOCATION}:/data
          - /etc/localtime:/etc/localtime:ro
        env_file:
          - .env
        ports:
          - '2283:2283'
        depends_on:
          - redis
          - database
        restart: always

      immich-machine-learning:
        container_name: immich_machine_learning
        image: ghcr.io/immich-app/immich-machine-learning:${IMMICH_VERSION:-release}
        volumes:
          - model-cache:/cache

      redis:
        container_name: immich_redis
        image: docker.io/valkey/valkey:9@sha256:abc # pinned
        healthcheck:
          test: redis-cli ping || exit 1

      database:
        build: ./db
        ports:
          - "5432:5432"
          - 127.0.0.1:8080:80

    volumes:
      model-cache:
    """

    func testOverviewOfAMultiServiceFileWithComments() {
        // A multi-service file is not something the one-container form can show.
        XCTAssertNil(ComposeFormParser.parse(immich))
        let o = ComposeFormParser.overview(of: immich)
        XCTAssertEqual(o.projectName, "immich")
        XCTAssertEqual(o.services.map(\.name), ["immich-server", "immich-machine-learning", "redis", "database"])
        XCTAssertEqual(o.services[0].image, "ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}")
        XCTAssertEqual(o.services[0].ports, ["2283:2283"])
        XCTAssertEqual(o.services[2].image, "docker.io/valkey/valkey:9@sha256:abc", "a trailing comment is dropped")
        XCTAssertTrue(o.services[3].build)
        XCTAssertNil(o.services[3].image)
        XCTAssertEqual(o.services[3].ports, ["5432:5432", "127.0.0.1:8080:80"])
        XCTAssertTrue(o.services[1].ports.isEmpty)
    }

    func testOverviewOfOddInput() {
        XCTAssertEqual(ComposeFormParser.overview(of: "").services.count, 0)
        XCTAssertEqual(ComposeFormParser.overview(of: "services:\n").services.count, 0)
        XCTAssertNil(ComposeFormParser.overview(of: "services:\n  a:\n    image: x\n").projectName)
        XCTAssertEqual(ComposeFormParser.overview(of: "name: \"my-app\"\nservices:\n  a:\n    image: x\n").projectName, "my-app")
    }

    func testUnsetVariablesAreReadFromComposeWarnings() {
        let result = ValidationResult(issues: [
            ComposeIssue(severity: .warning, line: nil, message: "The \"DB_PASSWORD\" variable is not set. Defaulting to a blank string."),
            ComposeIssue(severity: .warning, line: nil, message: "The \"UPLOAD_LOCATION\" variable is not set. Defaulting to a blank string."),
            ComposeIssue(severity: .warning, line: nil, message: "The \"DB_PASSWORD\" variable is not set. Defaulting to a blank string."),
            ComposeIssue(severity: .error, line: nil, message: "invalid spec: :/var/lib/postgresql/data: empty section between colons"),
            ComposeIssue(severity: .warning, line: nil, message: "The \"bad name\" variable is not set."),
        ])
        XCTAssertEqual(result.unsetVariables, ["DB_PASSWORD", "UPLOAD_LOCATION"])
        XCTAssertEqual(ValidationResult(issues: []).unsetVariables, [])
    }
}
