//
//  SensorStream.swift
//  The sensor channel: the device's physical sensors, 28 bytes at a time.
//
//  Our own addition to the agent (marker 'S', flag 0x100 — see refs/studio/PROVENANCE.md). Each
//  packet is little-endian: an int64 sensor timestamp, four float32 values, and a uint32 tag that
//  says which sensor they came from. Tag 1 is the rotation vector quaternion x, y, z, w mapping
//  the device frame into Android's East-North-Up world frame; tag 2 is a foldable's hinge angle
//  and tags 3 and 4 its two gyroscopes, which are kept fresh but not yet used.
//
//  The timestamps matter. Over Wi-Fi the packets arrive in clumps — a fold's 5° steps land three
//  or four at a time, tens of ms late — and rendering "the newest value" turns a smooth motion
//  into stutter-and-catch-up. So the stream keeps a short history of samples keyed by the
//  SENSOR's clock, estimates the phone→Mac clock offset from the least-delayed recent packet
//  (the 50 Hz rotation vector refreshes that every window), and answers `hinge(delay:)` and
//  `orientation(delay:)` by interpolating at "now, minus a small fixed delay" in sensor time —
//  a jitter buffer, as a video player has. Constant small latency instead of variable jerks.
//  A jitter line goes to the log every few seconds so the link can be judged in numbers.
//
//  The format changed from an untagged 24-byte quaternion on 2026-09-11 when the agent learned
//  about foldables. The channel has no framing or version, so this reader and the agent in
//  build/agent must always match — change one, rebuild the other.
//

import Foundation
import simd

final class SensorStream {
    private static let packetSize = 28
    private static let tagRotation: UInt32 = 1
    private static let tagHinge: UInt32 = 2
    private static let tagGyroA: UInt32 = 3
    private static let tagGyroB: UInt32 = 4
    private static let historyLimit = 96
    /// The clock-offset window: the minimum delay over the current and previous windows is the
    /// offset, so a burst of late packets never drags it and a drift is followed within 2 s.
    private static let offsetWindow: TimeInterval = 2

    private struct Sample<T> {
        let stamp: TimeInterval        // sensor clock, seconds
        let value: T
    }

    private let socket: TCPSocket
    private var thread: Thread?
    private var stopping = false

    private let lock = NSLock()
    private var latestQuat: simd_quatf?
    private var latestHingeDegrees: Float?
    private var latestGyros: [simd_float3?] = [nil, nil]
    private var packets = 0
    private var quatHistory: [Sample<simd_quatf>] = []
    private var hingeHistory: [Sample<Float>] = []
    // Clock offset: host uptime − sensor stamp, as small as any packet has shown it lately.
    private var offsetCurrent: TimeInterval?
    private var offsetPrevious: TimeInterval?
    private var offsetWindowStart: TimeInterval = 0
    // Jitter: each packet's delay beyond the offset, for the periodic log line.
    private var delays: [TimeInterval] = []
    private var delaysSince: TimeInterval = 0

    /// The newest device orientation, or nil before the first packet (or on a device with no
    /// rotation vector sensor — the channel simply stays silent). Any thread.
    var latest: simd_quatf? {
        lock.lock(); defer { lock.unlock() }
        return latestQuat
    }

    /// A foldable's hinge angle in degrees, 0 shut and 180 flat, or nil on a device without the
    /// sensor. The newest reading; `hinge(delay:)` is the smooth one. Any thread.
    var latestHinge: Float? {
        lock.lock(); defer { lock.unlock() }
        return latestHingeDegrees
    }

    /// The angular rate of one of a foldable's two IMUs (0 and 1), rad/s in the sensor frame, or
    /// nil on a device with one gyroscope. Which half each IMU sits in is a per-device fact the
    /// fold model resolves; here they are only kept fresh. Any thread.
    func latestGyro(_ which: Int) -> simd_float3? {
        lock.lock(); defer { lock.unlock() }
        return (0...1).contains(which) ? latestGyros[which] : nil
    }

    var packetsReceived: Int {
        lock.lock(); defer { lock.unlock() }
        return packets
    }

    /// The hinge angle as it was `delay` seconds ago in the sensor's own time, interpolated
    /// between the readings on either side. The sensor reports on change only, so a long gap
    /// before a reading means the angle held until just before it: the ramp into a reading is
    /// capped at 100 ms rather than stretched across the gap. Any thread.
    func hinge(delay: TimeInterval) -> Float? {
        lock.lock(); defer { lock.unlock() }
        guard let t = renderTimeLocked(delay: delay) else { return latestHingeDegrees }
        return Self.interpolate(hingeHistory, at: t) { a, b, f in a + (b - a) * f }
    }

    /// The orientation `delay` seconds ago in sensor time, slerped between neighbours. Any thread.
    func orientation(delay: TimeInterval) -> simd_quatf? {
        lock.lock(); defer { lock.unlock() }
        guard let t = renderTimeLocked(delay: delay) else { return latestQuat }
        return Self.interpolate(quatHistory, at: t) { a, b, f in simd_slerp(a, b, f) }
    }

    private func renderTimeLocked(delay: TimeInterval) -> TimeInterval? {
        guard let offset = clockOffsetLocked() else { return nil }
        return ProcessInfo.processInfo.systemUptime - offset - delay
    }

    private func clockOffsetLocked() -> TimeInterval? {
        switch (offsetCurrent, offsetPrevious) {
        case let (c?, p?): return min(c, p)
        case let (c?, nil): return c
        case let (nil, p?): return p
        default: return nil
        }
    }

    private static func interpolate<T>(_ history: [Sample<T>], at t: TimeInterval,
                                       _ mix: (T, T, Float) -> T) -> T? {
        guard let last = history.last else { return nil }
        if t >= last.stamp { return last.value }
        guard let first = history.first, t > first.stamp else { return history.first?.value }
        // The neighbours: the last sample at or before t, and the one after it.
        var lo = 0, hi = history.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if history[mid].stamp <= t { lo = mid } else { hi = mid }
        }
        let a = history[lo], b = history[hi]
        let rampStart = max(a.stamp, b.stamp - 0.1)
        if t <= rampStart { return a.value }
        let f = Float((t - rampStart) / max(b.stamp - rampStart, 1e-6))
        return mix(a.value, b.value, min(max(f, 0), 1))
    }

    init(socket: TCPSocket) {
        self.socket = socket
    }

    func start() {
        stopping = false
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "rplayhub.android.sensor"
        thread = t
        t.start()
    }

    func stop() {
        stopping = true
        socket.shutdownAndClose()
    }

    private func readLoop() {
        // No read timeout: a device lying still on a desk reports at the sensor rate anyway,
        // but there is no reason to treat a quiet spell as a failure.
        socket.setReadTimeout(0)
        while !stopping {
            guard let data = try? socket.readFully(Self.packetSize) else { break }
            let arrival = ProcessInfo.processInfo.systemUptime
            let (stampNs, tag, v): (Int64, UInt32, simd_float4) = data.withUnsafeBytes { raw in
                (raw.loadUnaligned(fromByteOffset: 0, as: Int64.self),
                 raw.loadUnaligned(fromByteOffset: 24, as: UInt32.self),
                 simd_float4(raw.loadUnaligned(fromByteOffset: 8, as: Float32.self),
                             raw.loadUnaligned(fromByteOffset: 12, as: Float32.self),
                             raw.loadUnaligned(fromByteOffset: 16, as: Float32.self),
                             raw.loadUnaligned(fromByteOffset: 20, as: Float32.self)))
            }
            let stamp = TimeInterval(stampNs) / 1e9
            lock.lock()
            noteArrivalLocked(arrival: arrival, stamp: stamp)
            switch tag {
            case Self.tagRotation:
                let q = simd_quatf(vector: v)
                if q.length > 0.5 {                       // else malformed or all-zero packet
                    let n = simd_normalize(q)
                    latestQuat = n
                    packets += 1
                    Self.append(&quatHistory, Sample(stamp: stamp, value: n))
                }
            case Self.tagHinge:
                latestHingeDegrees = v.x
                Self.append(&hingeHistory, Sample(stamp: stamp, value: v.x))
            case Self.tagGyroA, Self.tagGyroB:
                latestGyros[Int(tag - Self.tagGyroA)] = simd_float3(v.x, v.y, v.z)
            default:
                break      // a tag this build does not know; the packet is still 28 bytes
            }
            lock.unlock()
        }
        AppBuild.log("sensor stream ended")
    }

    private static func append<T>(_ history: inout [Sample<T>], _ sample: Sample<T>) {
        // Out-of-order stamps (two sensors sharing the tag would do it) are dropped rather than
        // let the binary search lie.
        if let last = history.last, sample.stamp < last.stamp { return }
        history.append(sample)
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
    }

    /// Every packet refines the clock offset and feeds the jitter figure. The log line reads
    /// "sensor: jitter p50 12 ms p95 41 ms max 90 ms over 250 pkts": what the link adds on top
    /// of its best case. A quiet link shows single digits; Wi-Fi power save shows bursts.
    private func noteArrivalLocked(arrival: TimeInterval, stamp: TimeInterval) {
        let d = arrival - stamp
        if arrival - offsetWindowStart > Self.offsetWindow {
            offsetPrevious = offsetCurrent
            offsetCurrent = nil
            offsetWindowStart = arrival
        }
        offsetCurrent = min(offsetCurrent ?? d, d)
        delays.append(d)
        if delaysSince == 0 { delaysSince = arrival }
        if arrival - delaysSince > 5, delays.count >= 20, let offset = clockOffsetLocked() {
            let sorted = delays.map { $0 - offset }.sorted()
            let p50 = sorted[sorted.count / 2], p95 = sorted[Int(Double(sorted.count) * 0.95)]
            AppBuild.log(String(format: "sensor: jitter p50 %.0f ms  p95 %.0f ms  max %.0f ms  over %d pkts",
                                p50 * 1000, p95 * 1000, sorted.last! * 1000, sorted.count))
            delays.removeAll(keepingCapacity: true)
            delaysSince = arrival
        }
    }
}
