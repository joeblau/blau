import AppKit
import CoreAudio
import SwiftData
import SwiftUI

@main
struct PilotApp: App {
    let modelContainer: ModelContainer

    @State private var store: WorkspaceStore
    @State private var deviceStatus = DeviceStatus()
    @State private var remoteTranscription = TranscriptionService()
    @State private var audioOutputMonitor = MacAudioOutputMonitor()
    @State private var syncService = PeerSyncService(
        role: .advertiser,
        displayName: Host.current().localizedName ?? "Mac"
    )

    init() {
        let schema = Schema([Workspace.self, Pane.self, BrowserState.self])
        let container = try! ModelContainer(for: schema)
        self.modelContainer = container
        self._store = State(initialValue: WorkspaceStore(modelContext: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, syncService: syncService, deviceStatus: deviceStatus, remoteTranscription: remoteTranscription, audioOutputMonitor: audioOutputMonitor)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .task {
                    _ = MouseBridge.shared.ensurePermissions()
                    startAudioMonitor()
                    setupSync()
                }
        }
        .modelContainer(modelContainer)
        .commands {
            CommandMenu("Browser") {
                Button("Focus Address Bar") {
                    NotificationCenter.default.post(name: .pilotFocusBrowserAddressBar, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(store.selectedWorkspace?.selectedPane?.kind != .browser)
            }
        }
    }

    private func startAudioMonitor() {
        audioOutputMonitor.start()
    }

    private func setupSync() {
        syncService.onReceive = { (message: SyncMessage) in
            switch message {
            case .selectWorkspace(let sel):
                store.selectedWorkspaceID = sel.workspaceID
            case .workspaceState:
                break
            case .deviceStatus(let status):
                deviceStatus = status
            case .mouseMove(let m):
                MouseBridge.shared.move(dx: m.dx, dy: m.dy)
            case .mouseClick:
                MouseBridge.shared.click()
            case .voiceRecord(let control):
                switch control {
                case .start:
                    Task { await remoteTranscription.start() }
                case .stop:
                    Task {
                        await remoteTranscription.stop()
                        let text = [remoteTranscription.finalText, remoteTranscription.partialText]
                            .filter { !$0.isEmpty }
                            .joined(separator: " ")
                            .replacingOccurrences(of: "Waiting for speech...", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        let pb = NSPasteboard.general
                        let saved = pb.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, Data)? in
                            guard let type = item.types.first,
                                  let data = item.data(forType: type) else { return nil }
                            return (type, data)
                        }
                        pb.clearContents()
                        pb.setString(text, forType: .string)
                        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            if let saved, !saved.isEmpty {
                                pb.clearContents()
                                for (type, data) in saved {
                                    pb.setData(data, forType: type)
                                }
                            }
                        }
                    }
                }
            case .terminalInput(let input):
                switch input {
                case .enter:
                    let event = NSEvent.keyEvent(
                        with: .keyDown,
                        location: .zero,
                        modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: NSApp.mainWindow?.windowNumber ?? 0,
                        context: nil,
                        characters: "\r",
                        charactersIgnoringModifiers: "\r",
                        isARepeat: false,
                        keyCode: 36 // Return key
                    )
                    if let event {
                        NSApp.mainWindow?.firstResponder?.keyDown(with: event)
                    }
                }
            }
        }
        syncService.start()

        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                guard syncService.isConnected else { return }
                let state = WorkspaceState(
                    workspaces: store.summaries,
                    selectedWorkspaceID: store.selectedWorkspaceID
                )
                syncService.send(.workspaceState(state))
            }
        }
    }
}

// MARK: - Mac Audio Output Monitor

@Observable
@MainActor
final class MacAudioOutputMonitor {
    var detectedKind: ConnectedDeviceKind?

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    func start() {
        refresh()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        listenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    func refresh() {
        guard let name = Self.defaultOutputDeviceName() else {
            detectedKind = nil
            return
        }
        detectedKind = Self.classifyDevice(name: name)
    }

    private static func defaultOutputDeviceName() -> String? {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &deviceID
        )
        guard status == noErr else { return nil }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var nameRef: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        let nameStatus = AudioObjectGetPropertyData(
            deviceID,
            &nameAddress,
            0, nil,
            &nameSize,
            &nameRef
        )
        guard nameStatus == noErr else { return nil }
        return nameRef as String
    }

    private static func classifyDevice(name: String) -> ConnectedDeviceKind? {
        let lowered = name.lowercased()

        // Built-in speakers are not headphones
        if lowered.contains("built-in") || lowered.contains("macbook") || lowered.contains("speakers") {
            return nil
        }

        if lowered.contains("airpods max") {
            return .airpodsMax
        } else if lowered.contains("airpods pro") {
            return .airpodsPro
        } else if lowered.contains("airpods") {
            return .airpods
        } else {
            // Any non-built-in device is treated as bluetooth headphones
            return .headphonesBluetooth
        }
    }
}
