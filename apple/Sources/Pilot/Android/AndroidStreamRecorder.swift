import AVFoundation
import CoreMedia
import Foundation
import OSLog

/// Passthrough recorder for the live mirror: remuxes the exact compressed
/// H.264 samples the display shows into an .mp4 with zero re-encode
/// (`AVAssetWriterInput` with nil outputSettings + a sourceFormatHint). No
/// device-side file, no 180 s cap, no pull step — and because sample PTS is
/// monotonic against the connection epoch, a recording continues seamlessly
/// across screenrecord respawns as long as the format stays byte-identical.
///
/// On a genuine format change (rotation, resolution fallback) the current file
/// is finalized and the next segment starts automatically ("part 2"), so no
/// footage is ever lost to a mid-recording rotation.
///
/// Threading mirrors `CaptureCoordinator`: all mutable state is lock-guarded;
/// `append` arrives on the stream queue while arm/stop come from the main
/// actor. Callbacks fire off-lock.
final class AndroidStreamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let logger = Logger(subsystem: "app.blau.pilot.android", category: "recorder")

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var format: CMVideoFormatDescription?
    private var url: URL?
    private var armed = false
    private var segment = 1
    /// Names follow-up segments after a mid-recording format change.
    private var makeSegmentURL: (@Sendable (Int) -> URL)?

    /// Called with the finished file and an error description (if any) each
    /// time a segment closes — including automatic rotation rollovers.
    var onSegmentFinished: (@Sendable (URL, String?) -> Void)?

    /// Arm the recorder; the writer is built on the first IDR sample so the
    /// file always starts on a sync frame.
    @discardableResult
    func arm(segmentURL: @escaping @Sendable (Int) -> URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard writer == nil, !armed else { return false }
        makeSegmentURL = segmentURL
        segment = 1
        url = segmentURL(1)
        armed = true
        return true
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return armed || writer != nil
    }

    /// Tee target for every sample the stream produces.
    func append(_ sample: CMSampleBuffer, isIDR: Bool, format: CMVideoFormatDescription) {
        lock.lock()
        if let currentFormat = self.format, writer != nil,
           !CMFormatDescriptionEqual(currentFormat, otherFormatDescription: format) {
            // Rotation or resolution change mid-recording: close this segment
            // and re-arm for the next, which starts on the next IDR below.
            let closing = takeWriterLocked()
            armed = true
            url = makeSegmentURL.map { make in
                segment += 1
                return make(segment)
            } ?? url
            lock.unlock()
            finish(closing, error: nil)
            lock.lock()
        }

        if armed, writer == nil {
            guard isIDR else {
                lock.unlock()
                return
            }
            buildWriterLocked(format: format, firstPTS: CMSampleBufferGetPresentationTimeStamp(sample))
        }
        guard let writer, let input else {
            lock.unlock()
            return
        }
        var failureMessage: String?
        if writer.status == .writing, input.isReadyForMoreMediaData {
            if !input.append(sample) {
                failureMessage = writer.error?.localizedDescription ?? "The recording writer rejected a video frame."
            }
        }
        if let failureMessage {
            let closing = takeWriterLocked()
            lock.unlock()
            finish(closing, error: failureMessage, cancelled: true)
            return
        }
        lock.unlock()
    }

    /// Stop and finalize. Safe from any context; also used on disconnect.
    /// A second stop is a harmless no-op: the writer is detached under the
    /// lock, so the writer-nil path below sees armed == false and returns.
    func stop(reason: String? = nil) {
        lock.lock()
        guard writer != nil else {
            let wasArmed = armed
            let pendingURL = url
            armed = false
            url = nil
            makeSegmentURL = nil
            lock.unlock()
            if wasArmed, let pendingURL {
                onSegmentFinished?(pendingURL, reason ?? "Recording stopped before the first video frame arrived.")
            }
            return
        }
        let closing = takeWriterLocked()
        makeSegmentURL = nil
        lock.unlock()
        finish(closing, error: reason)
    }

    // MARK: - Writer lifecycle

    private func buildWriterLocked(format: CMVideoFormatDescription, firstPTS: CMTime) {
        guard let url else { return }
        do {
            try? FileManager.default.removeItem(at: url)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            // nil outputSettings + sourceFormatHint = compressed passthrough.
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw NSError(domain: "app.blau.pilot.android", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "The recording writer cannot accept the video format.",
                ])
            }
            writer.add(input)
            guard writer.startWriting() else {
                throw writer.error ?? NSError(domain: "app.blau.pilot.android", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "The recording writer could not start.",
                ])
            }
            writer.startSession(atSourceTime: firstPTS)
            self.writer = writer
            self.input = input
            self.format = format
            armed = false
        } catch {
            let failedURL = url
            armed = false
            self.url = nil
            makeSegmentURL = nil
            let callback = onSegmentFinished
            logger.error("recorder start failed: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.global(qos: .userInitiated).async {
                callback?(failedURL, "Could not create recording: \(error.localizedDescription)")
            }
        }
    }

    private typealias ClosingWriter = (writer: AVAssetWriter, input: AVAssetWriterInput, url: URL)?

    /// Detach the live writer under the lock; the caller finalizes it off-lock.
    private func takeWriterLocked() -> ClosingWriter {
        guard let writer, let input, let url else {
            self.writer = nil
            self.input = nil
            self.format = nil
            self.url = nil
            armed = false
            return nil
        }
        let closing = (writer, input, url)
        self.writer = nil
        self.input = nil
        self.format = nil
        self.url = nil
        armed = false
        return closing
    }

    private func finish(_ closing: ClosingWriter, error reason: String?, cancelled: Bool = false) {
        guard let closing else { return }
        let callback = onSegmentFinished
        if cancelled {
            closing.writer.cancelWriting()
            callback?(closing.url, reason)
            return
        }
        closing.input.markAsFinished()
        closing.writer.finishWriting {
            let message = closing.writer.status == .failed
                ? closing.writer.error?.localizedDescription ?? "The recording could not be saved."
                : reason
            callback?(closing.url, message)
        }
    }
}
