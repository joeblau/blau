import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import ObjectiveC

/// Headless simulator screen capture via direct framebuffer `IOSurface` access —
/// ported from serve-sim's `FrameCapture`. Registers SimulatorKit screen
/// callbacks on the booted device's `com.apple.framebuffer.display` IO ports,
/// wraps the live `IOSurface` zero-copy into a `CVPixelBuffer`, and enqueues it
/// straight into the display layer. Just the device screen — no window, no
/// DeviceHub, no Screen Recording permission.
///
/// `@unchecked Sendable`: all mutable Obj-C state is confined to `captureQueue`;
/// the display-layer renderer's `enqueue` is the supported off-main sink.
final class SimulatorFramebuffer: NSObject, @unchecked Sendable {
    private let layer: AVSampleBufferDisplayLayer
    /// Called on `captureQueue` with the framebuffer pixel size, so the pane can
    /// map input coordinates against the right aspect ratio.
    private let onSize: @Sendable (Int, Int) -> Void

    private let captureQueue = DispatchQueue(label: "app.blau.simulator.framebuffer", qos: .userInteractive)
    private var ioClient: NSObject?
    private var descriptors: [NSObject] = []
    private var callbackUUIDs: [ObjectIdentifier: NSUUID] = [:]
    private var lastSeeds: [ObjectIdentifier: UInt32] = [:]
    private var frameCount: UInt64 = 0
    private var lastCaptureMs: UInt64 = 0
    private var idleTimer: DispatchSourceTimer?
    private var rewireTicks = 0
    private(set) var width = 0
    private(set) var height = 0

    private static let idleIntervalMs: UInt64 = 200

    init(layer: AVSampleBufferDisplayLayer, onSize: @escaping @Sendable (Int, Int) -> Void) {
        self.layer = layer
        self.onSize = onSize
        super.init()
    }

    func start(deviceUDID: String) throws {
        try captureQueue.sync {
            guard let device = SimPrivateFrameworks.findDevice(udid: deviceUDID) else {
                throw error(1, "Simulator \(deviceUDID) not found")
            }
            guard SimPrivateFrameworks.isBooted(device) else {
                throw error(2, "Simulator is not booted")
            }
            guard let io = device.perform(NSSelectorFromString("io"))?.takeUnretainedValue() as? NSObject else {
                throw error(3, "Failed to get simulator IO")
            }
            self.ioClient = io
            try wireUpFramebuffer()
        }
        startIdleTimer()
    }

    func stop() {
        idleTimer?.cancel()
        idleTimer = nil
        captureQueue.sync {
            let unregSel = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
            for desc in descriptors where desc.responds(to: unregSel) {
                if let uuid = callbackUUIDs[ObjectIdentifier(desc)] {
                    desc.perform(unregSel, with: uuid)
                }
            }
            callbackUUIDs.removeAll()
            descriptors.removeAll()
            lastSeeds.removeAll()
            ioClient = nil
        }
    }

    // MARK: - Wiring (captureQueue)

    private func wireUpFramebuffer() throws {
        guard let io = ioClient else { throw error(3, "No IO client") }
        io.perform(NSSelectorFromString("updateIOPorts"))

        let candidates = try framebufferDescriptors(io: io)

        let unregSel = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
        for old in descriptors where old.responds(to: unregSel) {
            if let uuid = callbackUUIDs[ObjectIdentifier(old)] { old.perform(unregSel, with: uuid) }
        }
        callbackUUIDs.removeAll()
        lastSeeds.removeAll()
        descriptors = candidates

        for desc in candidates { try registerCallbacks(desc) }

        if let best = bestDescriptor(),
           let surfObj = best.perform(NSSelectorFromString("framebufferSurface"))?.takeUnretainedValue() {
            let surf = unsafeBitCast(surfObj, to: IOSurface.self)
            width = IOSurfaceGetWidth(surf)
            height = IOSurfaceGetHeight(surf)
            onSize(width, height)
        }
        captureFrame()
    }

    private func framebufferDescriptors(io: NSObject) throws -> [NSObject] {
        guard let ports = io.value(forKey: "deviceIOPorts") as? [NSObject] else {
            throw error(4, "Failed to get IO ports")
        }
        let pidSel = NSSelectorFromString("portIdentifier")
        let descSel = NSSelectorFromString("descriptor")
        let surfSel = NSSelectorFromString("framebufferSurface")
        var result: [NSObject] = []
        for port in ports {
            guard port.responds(to: pidSel),
                  let pid = port.perform(pidSel)?.takeUnretainedValue(),
                  "\(pid)" == "com.apple.framebuffer.display",
                  port.responds(to: descSel),
                  let desc = port.perform(descSel)?.takeUnretainedValue() as? NSObject,
                  desc.responds(to: surfSel)
            else { continue }
            result.append(desc)
        }
        if result.isEmpty { throw error(5, "No framebuffer display found") }
        return result
    }

    private func bestDescriptor() -> NSObject? {
        let surfSel = NSSelectorFromString("framebufferSurface")
        var best: NSObject?
        var bestArea = 0
        for desc in descriptors {
            guard let surfObj = desc.perform(surfSel)?.takeUnretainedValue() else { continue }
            let surf = unsafeBitCast(surfObj, to: IOSurface.self)
            let area = IOSurfaceGetWidth(surf) * IOSurfaceGetHeight(surf)
            if area > bestArea { best = desc; bestArea = area }
        }
        return best
    }

    private func registerCallbacks(_ desc: NSObject) throws {
        let regSel = NSSelectorFromString("registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:")
        guard desc.responds(to: regSel) else { throw error(8, "registerScreenCallbacks unavailable") }
        guard let msgSendPtr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else {
            throw error(9, "objc_msgSend not found")
        }
        typealias MsgSend = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, AnyObject, AnyObject, AnyObject) -> Void
        let msgSend = unsafeBitCast(msgSendPtr, to: MsgSend.self)

        let uuid = NSUUID()
        callbackUUIDs[ObjectIdentifier(desc)] = uuid
        let frameCB: @convention(block) () -> Void = { [weak self] in
            self?.captureQueue.async { self?.captureFrame() }
        }
        let surfacesCB: @convention(block) () -> Void = { [weak self] in
            self?.captureQueue.async { self?.captureFrame() }
        }
        let propsCB: @convention(block) () -> Void = {}
        msgSend(desc, regSel, uuid, captureQueue as AnyObject,
                frameCB as AnyObject, surfacesCB as AnyObject, propsCB as AnyObject)
    }

    // MARK: - Capture (captureQueue)

    private func captureFrame() {
        guard let desc = bestDescriptor(),
              let surfObj = desc.perform(NSSelectorFromString("framebufferSurface"))?.takeUnretainedValue()
        else { return }
        let surface = unsafeBitCast(surfObj, to: IOSurface.self)

        let key = ObjectIdentifier(desc)
        let seed = IOSurfaceGetSeed(surface)
        let nowMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
        let seedChanged = lastSeeds[key] != seed
        let idleDue = frameCount > 0 && (nowMs &- lastCaptureMs) >= Self.idleIntervalMs
        if frameCount > 0, !seedChanged, !idleDue { return }
        lastSeeds[key] = seed

        let w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface)
        guard w > 0, h > 0 else { return }
        if width != w || height != h { width = w; height = h; onSize(w, h) }

        var pixelBuffer: Unmanaged<CVPixelBuffer>?
        let status = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surface,
            [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pb = pixelBuffer?.takeRetainedValue() else { return }

        lastCaptureMs = nowMs
        frameCount += 1
        enqueue(pb)
    }

    /// Wrap the IOSurface-backed pixel buffer in a CMSampleBuffer (display-
    /// immediately) and hand it to the layer's renderer.
    private func enqueue(_ pixelBuffer: CVPixelBuffer) {
        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc
        ) == noErr, let fmt = formatDesc else { return }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer
        ) == noErr, let sb = sampleBuffer else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately as NSString] = true
        }

        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
        renderer.enqueue(sb)
    }

    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + .milliseconds(Int(Self.idleIntervalMs)),
                       repeating: .milliseconds(Int(Self.idleIntervalMs)))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if (DispatchTime.now().uptimeNanoseconds / 1_000_000) &- self.lastCaptureMs >= Self.idleIntervalMs {
                self.captureFrame()
            }
            // Self-heal: if no frame has arrived, the descriptors are likely
            // stale — re-wire every ~1s until frames flow.
            if self.frameCount == 0 {
                self.rewireTicks += 1
                if self.rewireTicks % 5 == 0 { try? self.wireUpFramebuffer() }
            }
        }
        timer.resume()
        idleTimer = timer
    }

    private func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "SimulatorFramebuffer", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
