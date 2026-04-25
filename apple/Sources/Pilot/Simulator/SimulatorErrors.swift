import Foundation

enum SimulatorError: LocalizedError, Sendable, Equatable {
    case xcodeNotFound
    case spiUnavailable(symbol: String)
    case frameworkLoadFailed(path: String, detail: String)
    case deviceSetInitFailed(underlying: String)
    case runtimeNotInstalled(identifier: String)
    case deviceTypeNotAvailable(identifier: String)
    case deviceCreateFailed(underlying: String)
    case bootFailed(underlying: String)
    case bootTimeout(seconds: Int)
    case shutdownFailed(underlying: String)
    case framebufferSubscribeFailed(underlying: String)
    case framebufferDisconnected
    case inputSendFailed(underlying: String)
    case xpcDisconnected
    case logStreamEnded

    var errorDescription: String? {
        switch self {
        case .xcodeNotFound:
            return "Pilot could not find Xcode. Install Xcode 26 (or newer) from the App Store, then run `sudo xcode-select -s /Applications/Xcode.app`."
        case .spiUnavailable(let symbol):
            return "Pilot cannot use the iOS simulator because Apple's CoreSimulator framework is missing the symbol `\(symbol)`. This usually means your macOS or Xcode version is too new for this Pilot build."
        case .frameworkLoadFailed(let path, let detail):
            return "Pilot could not load Apple's private framework `\(path)`. \(detail) On macOS 14+ the framework lives at `/Library/Developer/PrivateFrameworks/`. Check that Xcode is installed and `xcode-select -p` points at it."
        case .deviceSetInitFailed(let underlying):
            return "Pilot could not prepare its simulator device pool: \(underlying)"
        case .runtimeNotInstalled(let identifier):
            return "iOS runtime `\(identifier)` is not installed. Open Xcode → Settings → Platforms and install it."
        case .deviceTypeNotAvailable(let identifier):
            return "Device type `\(identifier)` is not available in this Xcode install."
        case .deviceCreateFailed(let underlying):
            return "Creating the simulator device failed: \(underlying)"
        case .bootFailed(let underlying):
            return "The simulator failed to boot: \(underlying)"
        case .bootTimeout(let seconds):
            return "The simulator did not finish booting within \(seconds) seconds. It may be stuck — try closing this pane and opening a new one."
        case .shutdownFailed(let underlying):
            return "Shutting the simulator down failed: \(underlying)"
        case .framebufferSubscribeFailed(let underlying):
            return "Could not start the simulator screen stream: \(underlying)"
        case .framebufferDisconnected:
            return "The simulator screen stream disconnected and could not be restored. Close and reopen this pane."
        case .inputSendFailed(let underlying):
            return "Sending input to the simulator failed: \(underlying)"
        case .xpcDisconnected:
            return "Pilot lost its connection to the CoreSimulator service. Click the pane to attempt reconnect."
        case .logStreamEnded:
            return "The log stream ended."
        }
    }
}
