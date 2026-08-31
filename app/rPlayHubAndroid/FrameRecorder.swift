//
//  FrameRecorder.swift
//  Records decoded video frames (CVPixelBuffers) to an .mp4 on the Mac, via AVAssetWriter.
//
//  This is host-side recording of exactly what the viewer shows — used for the fusion window,
//  whose virtual display Android's own `screenrecord` refuses to capture (it accepts only
//  physical displays). It also sidesteps screenrecord's three-minute cap. Frames are H.264
//  re-encoded from the already-decoded pictures; timestamps come from a monotonic wall clock, so
//  the recording plays at real speed regardless of frame rate.
//

import AVFoundation
import CoreVideo

final class FrameRecorder {
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CFTimeInterval = 0
    private var frameCount = 0
    private let queue = DispatchQueue(label: "rplayhub.recorder")

    var isRecording: Bool { writer != nil }

    /// Begin recording to `url`, sized to the display. Writing starts immediately, so a later
    /// stop is always valid even if no frame ever arrives (a static display emits nothing).
    func start(to url: URL, width: Int, height: Int) {
        queue.sync {
            try? FileManager.default.removeItem(at: url)
            guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
            let vinput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            vinput.expectsMediaDataInRealTime = true
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ]
            let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vinput,
                                                          sourcePixelBufferAttributes: attrs)
            // Order matters: add inputs, THEN startWriting, THEN startSession. Calling
            // startWriting first flips status to .writing and addInput would throw.
            guard w.canAdd(vinput) else { return }
            w.add(vinput)
            guard w.startWriting() else { return }
            w.startSession(atSourceTime: .zero)
            writer = w
            input = vinput
            adaptor = ad
            startTime = CACurrentMediaTime()
            frameCount = 0
        }
    }

    /// Append one decoded frame. Safe to call from the decode callback; no-op when not recording.
    func append(_ pixelBuffer: CVPixelBuffer) {
        queue.async { [weak self] in
            guard let self, let input = self.input, let adaptor = self.adaptor,
                  input.isReadyForMoreMediaData else { return }   // drop if the encoder is behind
            let elapsed = CACurrentMediaTime() - self.startTime
            let time = CMTime(seconds: elapsed, preferredTimescale: 600)
            if adaptor.append(pixelBuffer, withPresentationTime: time) { self.frameCount += 1 }
        }
    }

    /// Finish and flush the file, then call back on the main queue with the finished URL (or nil
    /// when nothing was recorded — e.g. a static display that produced no frames).
    func stop(completion: @escaping (URL?) -> Void) {
        queue.async { [weak self] in
            guard let self, let writer = self.writer, let input = self.input else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            let url = writer.outputURL
            guard self.frameCount > 0 else {
                writer.cancelWriting()      // an empty file would be invalid; don't finalize it
                self.teardown()
                DispatchQueue.main.async { completion(nil) }
                return
            }
            input.markAsFinished()
            writer.finishWriting {
                let ok = writer.status == .completed
                self.teardown()
                DispatchQueue.main.async { completion(ok ? url : nil) }
            }
        }
    }

    private func teardown() {
        writer = nil
        input = nil
        adaptor = nil
        frameCount = 0
    }
}
