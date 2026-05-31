import SwiftUI
import UIKit

@main
struct PlotterApp: App {
    /// High-bandwidth frame channel that receives Pilot's mirrored window.
    @State private var mirror = MirrorModel()

    var body: some Scene {
        WindowGroup {
            ContentView(mirror: mirror)
                .task {
                    mirror.start()
                }
                .onDisappear {
                    mirror.stop()
                }
        }
    }
}
