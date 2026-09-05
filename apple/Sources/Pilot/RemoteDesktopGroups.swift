import Foundation

/// Local window layout. Connection metadata and credentials remain in their
/// existing SwiftData and Keychain stores; these slots only reference IDs.
struct RemoteDesktopGroup: Codable, Equatable, Identifiable {
    static let capacity = 4
    var id = UUID()
    var name: String
    var slots: [UUID?] = Array(repeating: nil, count: capacity)

    var connectionIDs: [UUID] { slots.compactMap { $0 } }
    var isFull: Bool { connectionIDs.count == Self.capacity }
}

@MainActor
@Observable
final class RemoteDesktopGroups {
    private(set) var groups: [RemoteDesktopGroup] = []
    var selectedGroupID: UUID? {
        didSet { save() }
    }

    @ObservationIgnored private let defaults: UserDefaults
    private static let storageKey = "remoteDesktopGroups.v1"

    private struct Layout: Codable {
        var groups: [RemoteDesktopGroup]
        var selectedGroupID: UUID?
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let layout = try? JSONDecoder().decode(Layout.self, from: data) {
            groups = layout.groups
            selectedGroupID = layout.selectedGroupID
        }
    }

    var selectedGroup: RemoteDesktopGroup? { groups.first { $0.id == selectedGroupID } }

    /// Seed existing saved machines in order, four per group. Deletions clear
    /// their slots without shifting any other machine's screen position.
    func reconcile(connectionIDs: [UUID]) {
        let known = Set(connectionIDs)
        var assigned = Set<UUID>()
        for index in groups.indices {
            var slots = Array(groups[index].slots.prefix(RemoteDesktopGroup.capacity))
            slots += Array(repeating: nil, count: RemoteDesktopGroup.capacity - slots.count)
            for slot in slots.indices {
                guard let id = slots[slot] else { continue }
                if !known.contains(id) || !assigned.insert(id).inserted { slots[slot] = nil }
            }
            groups[index].slots = slots
        }
        if groups.isEmpty { groups.append(RemoteDesktopGroup(name: "Group 1")) }
        for id in connectionIDs where !assigned.contains(id) {
            if groups.allSatisfy(\.isFull) { groups.append(makeGroup()) }
            guard let index = groups.firstIndex(where: { !$0.isFull }),
                  let slot = groups[index].slots.firstIndex(of: nil) else { continue }
            groups[index].slots[slot] = id
            assigned.insert(id)
        }
        if selectedGroup == nil { selectedGroupID = groups.first?.id }
        save()
    }

    @discardableResult
    func addGroup() -> UUID {
        let group = makeGroup()
        groups.append(group)
        selectedGroupID = group.id
        return group.id
    }

    func renameGroup(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = trimmed
        save()
    }

    func deleteEmptyGroup(_ id: UUID) {
        guard groups.count > 1,
              let index = groups.firstIndex(where: { $0.id == id }),
              groups[index].connectionIDs.isEmpty else { return }
        groups.remove(at: index)
        if selectedGroupID == id { selectedGroupID = groups.first?.id }
        save()
    }

    /// Validate the destination before removing the source so a full group
    /// cannot lose a machine. Explicit slots support dragging into blank cells.
    @discardableResult
    func place(_ connectionID: UUID, in groupID: UUID, slot requestedSlot: Int? = nil) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        if requestedSlot == nil, groups[index].connectionIDs.contains(connectionID) { return true }
        guard let slot = requestedSlot ?? groups[index].slots.firstIndex(of: nil),
              groups[index].slots.indices.contains(slot),
              groups[index].slots[slot] == nil || groups[index].slots[slot] == connectionID else { return false }
        for group in groups.indices {
            for position in groups[group].slots.indices where groups[group].slots[position] == connectionID {
                groups[group].slots[position] = nil
            }
        }
        groups[index].slots[slot] = connectionID
        save()
        return true
    }

    private func makeGroup() -> RemoteDesktopGroup {
        var number = 1
        while groups.contains(where: { $0.name == "Group \(number)" }) { number += 1 }
        return RemoteDesktopGroup(name: "Group \(number)")
    }

    private func save() {
        let layout = Layout(groups: groups, selectedGroupID: selectedGroupID)
        if let data = try? JSONEncoder().encode(layout) { defaults.set(data, forKey: Self.storageKey) }
    }
}
