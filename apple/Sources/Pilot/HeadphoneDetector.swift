import CoreAudio
import Foundation

// macOS headphone/audio output detection via Core Audio HAL.
//
// Monitors the default output device and classifies it using
// transport type + device name heuristics. No IOBluetooth, no
// CoreBluetooth, no third-party dependencies.
//
// Classification decision tree:
//
//   transport type?
//   ├── built-in → .speaker
//   ├── bluetooth → classify by name
//   │   ├── "airpods max" → .airpodsMax
//   │   ├── "airpods pro" → .airpodsPro
//   │   ├── "airpods" → .airpods
//   │   ├── "beats" → .beats
//   │   └── other → .headphonesBluetooth
//   ├── USB → .usb
//   ├── HDMI/DisplayPort → .speaker
//   ├── built-in + "headphone" in name → .headphonesWired
//   └── unknown → .unknown

@MainActor
@Observable
final class HeadphoneDetector {
    var audioOutput: AudioOutputDevice?

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var debounceTask: Task<Void, Never>?

    func start() {
        refresh()
        guard listenerBlock == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
            }
        }
        listenerBlock = block

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
        if status != noErr {
            listenerBlock = nil
        }
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil

        if let block = listenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                nil,
                block
            )
            listenerBlock = nil
        }
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            self.refresh()
        }
    }

    private func refresh() {
        audioOutput = Self.classifyDefaultOutputDevice()
    }

    // MARK: - Core Audio queries

    private static func classifyDefaultOutputDevice() -> AudioOutputDevice? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        let name = deviceName(deviceID) ?? ""
        let transport = transportType(deviceID)
        let manufacturer = deviceManufacturer(deviceID)
        let modelUID = deviceModelUID(deviceID)
        let kind = classifyDevice(name: name, transport: transport, manufacturer: manufacturer, modelUID: modelUID)
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return AudioOutputDevice(
            kind: kind,
            name: displayName.isEmpty ? kind.displayName : displayName
        )
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr, let cfName = name?.takeUnretainedValue() else { return nil }
        return cfName as String
    }

    private static func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        guard status == noErr else { return 0 }
        return transport
    }

    private static func deviceManufacturer(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyManufacturer,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mfg: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &mfg)
        guard status == noErr, let cfMfg = mfg?.takeUnretainedValue() else { return nil }
        return cfMfg as String
    }

    private static func deviceModelUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyModelUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var model: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &model)
        guard status == noErr, let cfModel = model?.takeUnretainedValue() else { return nil }
        return cfModel as String
    }

    // MARK: - Classification

    // Classification priority:
    //   1. Transport type (built-in, USB, HDMI, AirPlay)
    //   2. For Bluetooth: manufacturer + modelUID (deterministic, survives renames)
    //   3. Fallback: device name heuristics
    //
    // Apple BT audio devices always report manufacturer "Apple Inc." and use
    // short hex ModelUIDs (e.g. "2027 4c"). Third-party devices use
    // descriptive ModelUIDs (e.g. "CONNECT 6:29C2:0005").
    private static func classifyDevice(
        name: String,
        transport: UInt32,
        manufacturer: String?,
        modelUID: String?
    ) -> ConnectedDeviceKind {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            if name.lowercased().contains("headphone") {
                return .headphonesWired
            }
            return .speaker

        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE:
            // Apple BT audio = AirPods or Beats. Use manufacturer as the
            // deterministic signal (works even when user renames their device).
            if manufacturer?.contains("Apple") == true {
                // Try name first for specific model (works with default names)
                let byName = ConnectedDeviceKind.classify(name: name, defaultKind: .airpods)
                return byName
            }
            // Non-Apple BT: try name, fall back to generic bluetooth
            return ConnectedDeviceKind.classify(name: name, defaultKind: .headphonesBluetooth)

        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort:
            return .speaker
        case kAudioDeviceTransportTypeAirPlay:
            return .speaker
        default:
            return .unknown
        }
    }
}
