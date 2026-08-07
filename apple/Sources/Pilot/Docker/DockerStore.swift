import Foundation
import Observation

/// Live state behind the Docker section.
///
/// Owns the engine handshake, the container list, and the `/events` watch that
/// keeps the list honest without polling hard. Every mutation lands on the main
/// actor so SwiftUI observes it directly; only the socket I/O leaves.
@Observable
@MainActor
final class DockerStore {
    /// Whether Pilot has an engine to talk to, and why not when it doesn't.
    enum Engine: Equatable {
        case checking
        case unavailable(reason: String)
        case connected(version: DockerEngineVersion, socketPath: String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    private(set) var engine: Engine = .checking
    private(set) var containers: [DockerContainerSummary] = []
    private(set) var isRefreshing = false
    /// Last failed lifecycle action, shown as a dismissible banner. Cleared by
    /// the next successful action or refresh.
    private(set) var actionError: String?
    /// Containers with an action in flight, so their row shows progress and
    /// can't be double-fired.
    private(set) var busyContainerIDs: Set<String> = []

    var searchText = ""
    var selectedContainerID: String?
    var showsStopped: Bool {
        didSet { defaults.set(showsStopped, forKey: Self.showsStoppedKey) }
    }

    /// Set when a remove was requested, so the view can confirm before the
    /// irreversible delete. Transient — mirrors the Remote Desktop pattern.
    var containerPendingRemoval: DockerContainerSummary?

    private let defaults: UserDefaults
    private let makeClient: @MainActor (String) -> DockerEngineClient
    private let resolveSocketPath: @MainActor () -> String?
    private var client: DockerEngineClient?
    private var connectTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var isRunning = false

    private static let showsStoppedKey = "docker.showsStopped"
    /// How often the safety-net poll runs. `/events` carries state changes
    /// promptly; this exists for the things no event announces (a status string
    /// aging from "Up 3 minutes" to "Up 4 minutes") and for recovering after a
    /// dropped stream.
    private static let pollInterval = Duration.seconds(15)

    init(
        defaults: UserDefaults = .standard,
        resolveSocketPath: @escaping @MainActor () -> String? = { DockerSocketLocator.resolve() },
        makeClient: @escaping @MainActor (String) -> DockerEngineClient = { DockerEngineClient(socketPath: $0) }
    ) {
        self.defaults = defaults
        self.resolveSocketPath = resolveSocketPath
        self.makeClient = makeClient
        // Default to showing stopped containers: the list is as much "what can I
        // bring up" as "what is up".
        self.showsStopped = defaults.object(forKey: Self.showsStoppedKey) as? Bool ?? true
    }

    // MARK: - Lifecycle

    /// Begin (or resume) watching the daemon. Idempotent — the view calls this
    /// every time the section appears.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        connect()
        startPoll()
    }

    /// Stop all socket work. The section is a full-detail mode, so leaving it
    /// leaves nothing running behind it.
    func stop() {
        isRunning = false
        connectTask?.cancel()
        connectTask = nil
        eventsTask?.cancel()
        eventsTask = nil
        pollTask?.cancel()
        pollTask = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Re-run the handshake from scratch — the Retry button, and the path back
    /// after the user starts their engine.
    func reconnect() {
        engine = .checking
        isRunning = true
        connect()
        startPoll()
    }

    /// Handshake, then load the list and start watching. Replaces any in-flight
    /// attempt so repeated Retry taps can't stack up.
    private func connect() {
        eventsTask?.cancel()
        eventsTask = nil

        guard let socketPath = resolveSocketPath() else {
            client = nil
            containers = []
            engine = .unavailable(reason: "No Docker socket found on this Mac.")
            return
        }

        let client = makeClient(socketPath)
        self.client = client
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            do {
                let version = try await client.version()
                guard let self, !Task.isCancelled else { return }
                engine = .connected(version: version, socketPath: socketPath)
                await reload()
                guard isRunning, !Task.isCancelled else { return }
                watchEvents()
            } catch {
                guard let self, !Task.isCancelled else { return }
                containers = []
                engine = .unavailable(reason: Self.describe(error))
            }
        }
    }

    // MARK: - Refreshing

    /// Coalesced refresh. Events arrive in bursts — a compose stack coming up
    /// fires one per container — so a scheduled refresh replaces any pending one
    /// instead of queueing a list call per event.
    func scheduleRefresh() {
        guard client != nil else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            await reload()
        }
    }

    func refreshNow() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.reload()
        }
    }

    private func reload() async {
        guard let client else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fetched = try await client.containers()
            guard !Task.isCancelled else { return }
            containers = fetched
            actionError = nil
            if let selectedContainerID, !fetched.contains(where: { $0.id == selectedContainerID }) {
                self.selectedContainerID = nil
            }
        } catch {
            guard !Task.isCancelled else { return }
            containers = []
            engine = .unavailable(reason: Self.describe(error))
        }
    }

    /// One loop that both refreshes while connected and retries the handshake
    /// while not, so an engine started after Pilot launched is picked up without
    /// the user touching Retry.
    private func startPoll() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, !Task.isCancelled, isRunning else { return }
                if engine.isConnected {
                    await reload()
                } else {
                    connect()
                }
            }
        }
    }

    private func watchEvents() {
        guard let client else { return }
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            // Reconnect with a fixed backoff if the daemon restarts or the
            // stream drops; the poll above covers the gap in the meantime.
            while !Task.isCancelled {
                do {
                    for try await _ in client.containerEvents() {
                        guard let self, !Task.isCancelled else { return }
                        scheduleRefresh()
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                }
                guard let self, !Task.isCancelled, isRunning else { return }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    // MARK: - Actions

    func perform(_ action: DockerContainerAction, on container: DockerContainerSummary) {
        guard let client, !busyContainerIDs.contains(container.id) else { return }
        busyContainerIDs.insert(container.id)
        Task { [weak self] in
            do {
                try await client.perform(action, containerID: container.id)
                guard let self else { return }
                busyContainerIDs.remove(container.id)
                actionError = nil
                await reload()
            } catch {
                guard let self else { return }
                busyContainerIDs.remove(container.id)
                actionError = "\(action.label) “\(container.name)” failed: \(Self.describe(error))"
            }
        }
    }

    func requestRemoval(of container: DockerContainerSummary) {
        containerPendingRemoval = container
    }

    func dismissActionError() {
        actionError = nil
    }

    // MARK: - Presentation

    /// Containers after the "show stopped" toggle and the search field, running
    /// first and alphabetical within each group so the list doesn't reshuffle as
    /// statuses tick over.
    var visibleContainers: [DockerContainerSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return containers
            .filter { showsStopped || $0.state.isRunning }
            .filter { container in
                guard !query.isEmpty else { return true }
                return container.name.lowercased().contains(query)
                    || container.image.lowercased().contains(query)
                    || container.shortID.contains(query)
                    || (container.composeProject?.lowercased().contains(query) ?? false)
            }
            .sorted { lhs, rhs in
                if lhs.state.isRunning != rhs.state.isRunning { return lhs.state.isRunning }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// One section per compose project, standalone containers last. Groups are
    /// ordered by name so the list is stable across refreshes.
    struct ContainerGroup: Identifiable {
        let id: String
        let title: String
        let isCompose: Bool
        let containers: [DockerContainerSummary]
    }

    var groupedContainers: [ContainerGroup] {
        let grouped = Dictionary(grouping: visibleContainers) { $0.composeProject }
        var groups = grouped
            .compactMap { project, items -> ContainerGroup? in
                guard let project else { return nil }
                return ContainerGroup(id: project, title: project, isCompose: true, containers: items)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        if let standalone = grouped[String?.none] ?? nil, !standalone.isEmpty {
            groups.append(
                ContainerGroup(id: "__standalone", title: "Standalone", isCompose: false, containers: standalone)
            )
        }
        return groups
    }

    var runningCount: Int {
        containers.filter { $0.state.isRunning }.count
    }

    private static func describe(_ error: any Error) -> String {
        if let transportError = error as? DockerTransportError {
            return transportError.errorDescription ?? "\(transportError)"
        }
        return error.localizedDescription
    }
}
