import SwiftUI
import UIKit

@main
struct PlotterApp: App {
    /// High-bandwidth frame channel that receives Pilot's mirrored window.
    @State private var mirror = MirrorModel()

    var body: some Scene {
        WindowGroup {
            ContentView(mirror: mirror)
                // While connected, match Pilot's light/dark mode; when not
                // connected, `pilotColorScheme` is nil so Plotter follows its
                // own system appearance.
                .preferredColorScheme(mirror.pilotColorScheme)
                .task {
                    mirror.start()
                }
                .onDisappear {
                    mirror.stop()
                }
        }
    }
}
