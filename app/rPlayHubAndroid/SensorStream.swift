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
//  SENSOR's clock, estimates the phone→Mac clock offset from the least-delayed packet (allowed
//  to creep up slowly for drift), and answers `hinge()` and `orientation()` by interpolating at
//  "now, minus the jitter the link shows" in sensor time — a jitter buffer, as a video player
//  has. The render clock runs at real speed and slews to a changed buffer size; it never jumps.
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
    /// How fast a clock offset may creep upward, seconds per second. Packets can only arrive late,
    /// never early, so the smallest delay seen is the offset; letting it rise this slowly follows
    /// a drift between the two clocks without ever stepping.
    private static let offsetDrift: TimeInterval = 0.002
    /// How much faster or slower than real time the render clock may run while it catches up to
    /// a changed target. 10%: a 150 ms change in the buffer takes 1.5 s and is invisible.
    private static let slewRate: TimeInterval = 0.10

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
    // Clock offset per sensor tag: host uptime − sensor stamp, as small as any packet of that
    // tag has shown it lately. Per tag, because the sensors need not share a time base — a
    // fused rotation vector can stamp differently from a raw gyro — and one offset for all of
    // them would put the hinge's samples in the wrong place on the render clock.
    private struct Clock {
        var offset: TimeInterval?
        var lastArrival: TimeInterval = 0
        var delays: [TimeInterval] = []
        /// The 95th-percentile delay beyond the offset over the last logged window — what the
        /// jitter buffer must cover to stay smooth on this link.
        var recentP95: TimeInterval = 0
        /// The render clock: the sensor time last rendered and the host time it was rendered at.
        /// It advances with the host and slews toward its target; it never jumps or runs back,
        /// which is what made the model hop when the buffer resized.
        var renderSensor: TimeInterval?
        var renderHost: TimeInterval = 0
    }
    private var clocks: [UInt32: Clock] = [:]
    private var jitterLoggedAt: TimeInterval = 0

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
    func hinge(delay: TimeInterval? = nil) -> Float? {
        lock.lock(); defer { lock.unlock() }
        guard let t = renderTimeLocked(tag: Self.tagHinge, delay: delay) else { return latestHingeDegrees }
        return Self.interpolate(hingeHistory, at: t) { a, b, f in a + (b - a) * f }
    }

    /// The orientation `delay` seconds ago in sensor time, slerped between neighbours. Any thread.
    func orientation(delay: TimeInterval? = nil) -> simd_quatf? {
        lock.lock(); defer { lock.unlock() }
        guard let t = renderTimeLocked(tag: Self.tagRotation, delay: delay) else { return latestQuat }
        return Self.interpolate(quatHistory, at: t) { a, b, f in simd_slerp(a, b, f) }
    }

    /// `delay` nil means adaptive: the measured p95 jitter plus a margin, between 60 and 250 ms,
    /// so a quiet USB link renders close to live and a bursty Wi-Fi link trades a little latency
    /// for no freezes. The returned time is continuous: see Clock.renderSensor.
    private func renderTimeLocked(tag: UInt32, delay: TimeInterval?) -> TimeInterval? {
        guard var clock = clocks[tag], var offset = clock.offset else { return nil }
        // The sensors share the phone's boot clock in practice; a sensor that has reported little
        // (the hinge, on change only) borrows the rotation vector's better offset when the two agree.
        if tag != Self.tagRotation, let rot = clocks[Self.tagRotation]?.offset, abs(rot - offset) < 1 {
            offset = min(offset, rot)
        }
        let now = ProcessInfo.processInfo.systemUptime
        let d = delay ?? min(0.25, max(0.06, clock.recentP95 + 0.03))
        let target = now - offset - d
        var t = target
        if let last = clock.renderSensor {
            let dt = max(0, now - clock.renderHost)
            let advanced = last + dt
            let err = target - advanced
            if abs(err) < 0.5 {
                t = max(last, advanced + min(max(err, -Self.slewRate * dt), Self.slewRate * dt))
            }
        }
        clock.renderSensor = t
        clock.renderHost = now
        clocks[tag] = clock
        return t
    }

    private static func interpolate<T>(_ history: [Sample<T>], at t: TimeInterval,
                                       _ mix: (T, T, Float) -> T) -> T? {
        guard let last = history.last, let first = history.first else { return nil }
        // Beyond the newest sample: hold it. BEFORE the oldest: the render clock and this
        // sensor's stamps disagree (or the history is one packet old) — the newest value is the
        // honest fallback, never the oldest, which would freeze the model in the past.
        if t >= last.stamp || t <= first.stamp { return last.value }
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
            noteArrivalLocked(tag: tag, arrival: arrival, stamp: stamp)
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

    /// Every packet refines its sensor's clock offset and feeds the jitter figure. The log line
    /// reads "sensor: jitter rot p50 12 p95 41 max 90 ms · hinge p50 …": what the link adds on
    /// top of its best case, per sensor. A quiet link shows single digits; Wi-Fi power save shows
    /// bursts; a sensor whose numbers look nothing like the others' has its own time base.
    private func noteArrivalLocked(tag: UInt32, arrival: TimeInterval, stamp: TimeInterval) {
        var clock = clocks[tag] ?? Clock()
        let d = arrival - stamp
        if let o = clock.offset {
            clock.offset = min(o + (arrival - clock.lastArrival) * Self.offsetDrift, d)
        } else {
            clock.offset = d
        }
        clock.lastArrival = arrival
        clock.delays.append(d)
        clocks[tag] = clock

        if jitterLoggedAt == 0 { jitterLoggedAt = arrival }
        if arrival - jitterLoggedAt > 5 {
            jitterLoggedAt = arrival
            var parts: [String] = []
            for (t, name) in [(Self.tagRotation, "rot"), (Self.tagHinge, "hinge"), (Self.tagGyroA, "gyroA"), (Self.tagGyroB, "gyroB")] {
                guard var c = clocks[t], c.delays.count >= 5, let offset = c.offset else { continue }
                let sorted = c.delays.map { $0 - offset }.sorted()
                c.recentP95 = sorted[Int(Double(sorted.count) * 0.95)]
                // "buf": how far behind live the render clock actually sits right now.
                let buf = c.renderSensor.map { (arrival - offset - $0) * 1000 } ?? -1
                parts.append(String(format: "%@ p50 %.0f p95 %.0f max %.0f ms (%d) buf %.0f", name,
                                    sorted[sorted.count / 2] * 1000,
                                    sorted[Int(Double(sorted.count) * 0.95)] * 1000,
                                    sorted.last! * 1000, sorted.count, buf))
                c.delays.removeAll(keepingCapacity: true)
                clocks[t] = c
            }
            if !parts.isEmpty { AppBuild.log("sensor: jitter " + parts.joined(separator: " · ")) }
        }
    }
}
