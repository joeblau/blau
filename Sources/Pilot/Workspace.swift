import Foundation

@Observable
final class Workspace: Identifiable {
    let id: UUID
    var name: String

    init(name: String) {
        self.id = UUID()
        self.name = name
    }
}
