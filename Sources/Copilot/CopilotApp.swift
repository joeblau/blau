import SwiftUI

@main
struct CopilotApp: App {
    @State private var syncService = PeerSyncService(
        role: .browser,
        displayName: UIDevice.current.name
    )

    var body: some Scene {
        WindowGroup {
            ContentView(syncService: syncService)
        }
    }
}
