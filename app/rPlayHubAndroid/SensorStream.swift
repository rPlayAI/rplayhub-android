//
//  SensorStream.swift
//  The sensor channel: the device's physical sensors, 28 bytes at a time.
//
//  Our own addition to the agent (marker 'S', flag 0x100 — see refs/studio/PROVENANCE.md). Each
//  packet is little-endian: an int64 sensor timestamp, four float32 values, and a uint32 tag that
//  says which sensor they came from. Tag 1 is the rotation vector quaternion x, y, z, w mapping
//  the device frame into Android's East-North-Up world frame; tag 2 is a foldable's hinge angle
//  and tags 3 and 4 its two gyroscopes, which the Mac does not use yet and skips. The timestamp is
//  ignored too: every value is a "current value", and the newest packet always wins.
//
//  The format changed from an untagged 24-byte quaternion on 2026-09-11 when the agent learned
//  about foldables. The channel has no framing or version, so this reader and the agent in
//  build/agent must always match — change one, rebuild the other.
//
//  Nothing here renders or converts anything. The twin view pulls `latest` on its own render
//  clock; this thread just keeps that value fresh at the agent's 100 Hz.
//

import Foundation
import simd

final class SensorStream {
    private static let packetSize = 28
    private static let tagRotation: UInt32 = 1
    private static let tagHinge: UInt32 = 2
    private static let tagGyroA: UInt32 = 3
    private static let tagGyroB: UInt32 = 4

    private let socket: TCPSocket
    private var thread: Thread?
    private var stopping = false

    private let lock = NSLock()
    private var latestQuat: simd_quatf?
    private var latestHingeDegrees: Float?
    private var latestGyros: [simd_float3?] = [nil, nil]
    private var packets = 0

    /// The newest device orientation, or nil before the first packet (or on a device with no
    /// rotation vector sensor — the channel simply stays silent). Any thread.
    var latest: simd_quatf? {
        lock.lock(); defer { lock.unlock() }
        return latestQuat
    }

    /// A foldable's hinge angle in degrees, 0 shut and 180 flat, or nil on a device without the
    /// sensor. It reports on change only, in 5-degree steps about 20 ms apart, so the reader is
    /// expected to ease toward it. Any thread.
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
            let (tag, v): (UInt32, simd_float4) = data.withUnsafeBytes { raw in
                (raw.loadUnaligned(fromByteOffset: 24, as: UInt32.self),
                 simd_float4(raw.loadUnaligned(fromByteOffset: 8, as: Float32.self),
                             raw.loadUnaligned(fromByteOffset: 12, as: Float32.self),
                             raw.loadUnaligned(fromByteOffset: 16, as: Float32.self),
                             raw.loadUnaligned(fromByteOffset: 20, as: Float32.self)))
            }
            switch tag {
            case Self.tagRotation:
                let q = simd_quatf(vector: v)
                guard q.length > 0.5 else { continue }   // malformed or all-zero packet
                lock.lock()
                latestQuat = simd_normalize(q)
                packets += 1
                lock.unlock()
            case Self.tagHinge:
                lock.lock()
                latestHingeDegrees = v.x
                lock.unlock()
            case Self.tagGyroA, Self.tagGyroB:
                lock.lock()
                latestGyros[Int(tag - Self.tagGyroA)] = simd_float3(v.x, v.y, v.z)
                lock.unlock()
            default:
                continue   // a tag this build does not know; the packet is still 28 bytes
            }
        }
        AppBuild.log("sensor stream ended")
    }
}
