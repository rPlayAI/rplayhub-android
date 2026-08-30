//
//  VideoDecoder.swift
//  Explicit VideoToolbox decoding, and a layer that shows the pictures it produces.
//
//  Adopted from ~/rplay-hub, minus its RVRA machinery. That existed because displayservice
//  changes the coded resolution mid-GOP and signals it in a trailer on the slice NAL; MediaCodec
//  does not — a resolution change here arrives as fresh parameter sets, which rebuild the format
//  description and the session with it. So this is the plain shape of the same design.
//
//  What is kept, and why it matters just as much on this stream: decode and display are separate
//  stages. AVSampleBufferDisplayLayer decides for itself when to drop compressed samples, and it
//  drops them BEFORE decoding — which breaks the reference chain until the next keyframe. Here
//  every access unit is decoded, in order, unconditionally; only finished pictures are ever
//  skipped, and skipping one of those costs nothing.
//
//  This is also the shape the ports need. `~/rplay-hub/core/hwdecoder.h` is the common decoder
//  seam — VideoToolbox here, ffmpeg elsewhere — and it hands back frames, not sample buffers.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import VideoToolbox

final class VideoDecoder {
    /// Called on the decoding thread for every picture, in decode order.
    var onFrame: ((CVPixelBuffer) -> Void)?

    private(set) var framesDecoded = 0
    private(set) var decodeFailures = 0
    private(set) var lastError: String?

    /// When true the decoder asks VideoToolbox for BGRA output — single-plane, Metal-friendly,
    /// what the 3D twin's texture path takes — at the cost of a colour conversion per frame.
    /// The flat layer is happy with either. Read on the decode thread; the session is rebuilt
    /// when the value differs from the one it was created with, so flip it and then restart the
    /// video stream (fresh parameter sets + keyframe) for a clean switch.
    var outputBGRA = false

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sessionIsBGRA = false

    deinit { invalidate() }

    func invalidate() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        format = nil
    }

    /// Decode one access unit. Synchronous: VideoToolbox invokes the output callback before this
    /// returns, so pictures arrive in decode order with no reordering queue to manage. The agent
    /// configures MediaCodec for live streaming and emits no B-frames, so decode order is display
    /// order. Returns the decode status so the caller can react to data-level failures — a
    /// session-level failure is already handled here.
    @discardableResult
    func decode(_ sample: CMSampleBuffer) -> OSStatus {
        guard let desc = CMSampleBufferGetFormatDescription(sample),
              let session = ensureSession(for: desc) else { return noErr }

        var flags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: &flags)
        if status != noErr {
            decodeFailures += 1
            lastError = "decode failed (\(status))"
            // A session that has started refusing frames stays broken; rebuild it on the next
            // access unit rather than reporting the same error forever.
            if status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr {
                invalidate()
            }
        }
        return status
    }

    private func ensureSession(for desc: CMVideoFormatDescription) -> VTDecompressionSession? {
        if let session, let format, CMFormatDescriptionEqual(format, otherFormatDescription: desc),
           sessionIsBGRA == outputBGRA {
            return session
        }
        invalidate()

        // No destination attributes, so the decoder emits its native format and nothing converts
        // anything — AVSampleBufferDisplayLayer takes YCbCr directly. Asking for BGRA would make
        // VideoToolbox colour-convert every frame purely to satisfy a CALayer contents assignment.
        let spec: [String: Any] = [
            // Require, not merely enable. A software fallback keeps up on a still home screen and
            // falls behind exactly when a swipe raises the bit rate, which is the shape of the
            // symptom — better to fail loudly at session creation than to decode slowly.
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true,
        ]

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, image, _, _ in
                guard let refcon else { return }
                let me = Unmanaged<VideoDecoder>.fromOpaque(refcon).takeUnretainedValue()
                guard status == noErr, let image else {
                    me.decodeFailures += 1
                    me.lastError = "picture dropped by the decoder (\(status))"
                    return
                }
                me.framesDecoded += 1
                me.onFrame?(image)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())

        // See `outputBGRA` — nil attributes let the decoder emit its native YCbCr.
        let wantBGRA = outputBGRA
        let imageAttributes: [String: Any]? = wantBGRA ? [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ] : nil

        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: desc,
            decoderSpecification: spec as CFDictionary,
            imageBufferAttributes: imageAttributes as CFDictionary?,
            outputCallback: &callback,
            decompressionSessionOut: &created)
        guard status == noErr, let created else {
            decodeFailures += 1
            lastError = "could not create a decoder (\(status))"
            AppBuild.log("VTDecompressionSessionCreate failed: \(status)")
            return nil
        }
        session = created
        format = desc
        sessionIsBGRA = wantBGRA
        return created
    }
}

/// Shows decoded pictures, one per display refresh at most.
///
/// The newest decoded picture replaces the pending one, and a display link presents whatever is
/// pending when the screen is actually about to refresh. Handing every decoded picture straight
/// to the layer instead — from the decode thread, with DisplayImmediately — measured 55% of them
/// discarded by the layer on the iOS path, with the choice of which left to AppKit.
final class VideoLayer: AVSampleBufferDisplayLayer {
    /// Pictures decoded but never shown, superseded before a refresh came round. Not a loss:
    /// the decoder consumed every one, so the reference chain is intact.
    private(set) var framesSkipped = 0
    private(set) var framesPresented = 0

    private var format: CMVideoFormatDescription?
    private var pending: CVPixelBuffer?
    private let pendingLock = NSLock()
    private var displayLink: CVDisplayLink?

    override init() { super.init(); startDisplayLink() }
    override init(layer: Any) { super.init(layer: layer); startDisplayLink() }
    required init?(coder: NSCoder) { super.init(coder: coder); startDisplayLink() }

    deinit { if let displayLink { CVDisplayLinkStop(displayLink) } }

    /// CVDisplayLink is deprecated in favour of NSView.displayLink, but the presentation target
    /// here is a layer with no view of its own, and the layer is what the ports keep.
    private func startDisplayLink() {
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
              let link else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, ctx in
            guard let ctx else { return kCVReturnSuccess }
            Unmanaged<VideoLayer>.fromOpaque(ctx).takeUnretainedValue().displayTick()
            return kCVReturnSuccess
        }, me)
        CVDisplayLinkStart(link)
        displayLink = link
    }

    /// Called on the decode thread for every decoded picture. Cheap by design: it stores the
    /// picture and returns — no sample buffer built, nothing dispatched, nothing touching the
    /// layer, all on the thread that also reads the socket.
    func present(_ picture: CVPixelBuffer) {
        pendingLock.lock()
        if pending != nil { framesSkipped += 1 }
        pending = picture
        pendingLock.unlock()
    }

    private func displayTick() {
        pendingLock.lock()
        let picture = pending
        pending = nil
        pendingLock.unlock()
        guard let picture else { return }      // nothing new since the last refresh
        enqueueForDisplay(picture)
    }

    private func enqueueForDisplay(_ picture: CVPixelBuffer) {
        var desc = format
        if desc == nil || !CMVideoFormatDescriptionMatchesImageBuffer(desc!, imageBuffer: picture) {
            var made: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                    allocator: kCFAllocatorDefault,
                    imageBuffer: picture,
                    formatDescriptionOut: &made) == noErr, let made else { return }
            format = made
            desc = made
        }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: .invalid,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: picture,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: desc!,
                sampleTiming: &timing,
                sampleBufferOut: &sample) == noErr, let sample else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0),
                                     to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        // Flush only on hard failure. Flushing because the layer is merely "not ready" discards
        // what is already queued and starves the renderer.
        if status == .failed { flush() }
        if isReadyForMoreMediaData {
            enqueue(sample)
            framesPresented += 1
        } else {
            framesSkipped += 1
        }
    }
}
