import Foundation
import Testing
@testable import Pilot

/// Decoding of `/containers/json`, using the shape the daemon actually returns —
/// including the duplicate port rows it emits once per host address family, and
/// the fields it omits for a container that never ran.
@Suite("Docker container decoding")
struct DockerContainerDecodingTests {
    private let payload = """
    [
      {
        "Id": "e7e955d980309e253f725441669eb0e6eb2822d9e23e67b624ddd218aa7f5fb8",
        "Names": ["/local-graph-node-1"],
        "Image": "graphprotocol/graph-node:v0.44.0",
        "Command": "start",
        "Created": 1785798554,
        "Ports": [
          {"IP": "0.0.0.0", "PrivatePort": 8020, "PublicPort": 8020, "Type": "tcp"},
          {"IP": "::", "PrivatePort": 8020, "PublicPort": 8020, "Type": "tcp"},
          {"IP": "0.0.0.0", "PrivatePort": 8000, "PublicPort": 8000, "Type": "tcp"},
          {"PrivatePort": 9000, "Type": "tcp"}
        ],
        "Labels": {"com.docker.compose.project": "local"},
        "State": "running",
        "Status": "Up 42 hours"
      },
      {
        "Id": "b2d2b3ea8b28b9fae9abe63b47f7cffe96222494b8bb1f7d485bec5312a29b99",
        "Names": ["/lonely-redis"],
        "Image": "redis:7",
        "Created": 1785790000,
        "Ports": [],
        "Labels": {},
        "State": "exited",
        "Status": "Exited (0) 3 hours ago"
      }
    ]
    """

    private func decoded() throws -> [DockerContainerSummary] {
        try JSONDecoder().decode([DockerContainerSummary].self, from: Data(payload.utf8))
    }

    @Test("Names lose Docker's leading slash")
    func stripsLeadingSlashFromName() throws {
        let containers = try decoded()
        #expect(containers.count == 2)
        #expect(containers[0].name == "local-graph-node-1")
        #expect(containers[1].name == "lonely-redis")
    }

    @Test("Ports de-duplicate across address families and sort published first")
    func dedupesPorts() throws {
        let container = try #require(try decoded().first)
        // 8020 appears twice in the payload (0.0.0.0 and ::) but is one mapping.
        #expect(container.ports.count == 3)
        #expect(container.portsSummary == "8000→8000/tcp  8020→8020/tcp  9000/tcp")
    }

    @Test("State maps to the lifecycle enum, with unknown values kept benign")
    func decodesState() throws {
        let containers = try decoded()
        #expect(containers[0].state == .running)
        #expect(containers[0].state.isRunning)
        #expect(containers[1].state == .exited)
        #expect(!containers[1].state.isRunning)
        #expect(DockerContainerState(rawValue: "hibernating") == .unknown)
        #expect(DockerContainerState(rawValue: "RUNNING") == .running)
    }

    @Test("Missing optional fields decode rather than failing the whole list")
    func toleratesMissingFields() throws {
        let containers = try decoded()
        // The second entry has no Command at all.
        #expect(containers[1].command.isEmpty)
        #expect(containers[1].ports.isEmpty)
        #expect(containers[1].portsSummary.isEmpty)
    }

    @Test("Compose project labels drive grouping; unlabelled containers stand alone")
    func readsComposeProject() throws {
        let containers = try decoded()
        #expect(containers[0].composeProject == "local")
        #expect(containers[1].composeProject == nil)
    }

    @Test("Container metadata is sanitized before it reaches the UI")
    func sanitizesHostileMetadata() throws {
        let hostile = """
        [{"Id":"abc123def456789","Names":["/evil\\u0007name"],"Image":"x\\u0000y","Created":0,
          "State":"running","Status":"Up\\u00071 second","Ports":[],"Labels":{}}]
        """
        let containers = try JSONDecoder().decode([DockerContainerSummary].self, from: Data(hostile.utf8))
        let container = try #require(containers.first)
        #expect(container.name == "evilname")
        #expect(container.image == "xy")
        #expect(container.status == "Up1 second")
        #expect(container.shortID == "abc123def456")
    }

    @Test("An unnamed container falls back to its short id")
    func fallsBackToShortID() throws {
        let json = """
        [{"Id":"0123456789abcdef0123","Names":[],"Image":"scratch","Created":0,
          "State":"created","Status":"Created","Ports":[],"Labels":{}}]
        """
        let container = try #require(
            try JSONDecoder().decode([DockerContainerSummary].self, from: Data(json.utf8)).first
        )
        #expect(container.name == "0123456789ab")
    }

    @Test("Only the actions that would do something are offered")
    func actionsMatchState() {
        #expect(DockerContainerAction.remove.label == "Remove")
        #expect(DockerContainerState.paused.isRunning == false)
        #expect(DockerContainerState.restarting.isRunning)
    }
}

@Suite("Docker container grouping and filtering")
@MainActor
struct DockerStorePresentationTests {
    /// A store wired to a socket that does not exist, so nothing reaches the
    /// network: these tests cover only the presentation layer over an injected
    /// container list.
    private func makeStore() throws -> DockerStore {
        let suiteName = "DockerStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return DockerStore(defaults: defaults, resolveSocketPath: { nil })
    }

    @Test("With no socket on the machine the section reports an unavailable engine")
    func reportsMissingEngine() throws {
        let store = try makeStore()
        store.start()
        #expect(store.engine == .unavailable(reason: "No Docker socket found on this Mac."))
        #expect(store.containers.isEmpty)
        store.stop()
    }

    @Test("Show-stopped preference persists")
    func persistsShowStopped() throws {
        let suiteName = "DockerStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = DockerStore(defaults: defaults, resolveSocketPath: { nil })
        #expect(store.showsStopped)  // stopped containers are visible by default
        store.showsStopped = false

        let reopened = DockerStore(defaults: defaults, resolveSocketPath: { nil })
        #expect(!reopened.showsStopped)
    }
}
