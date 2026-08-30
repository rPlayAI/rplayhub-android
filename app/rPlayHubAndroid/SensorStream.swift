//
//  SensorStream.swift
//  The sensor channel: the device's physical orientation, 24 bytes at a time.
//
//  Our own addition to the agent (marker 'S', flag 0x100 — see refs/studio/PROVENANCE.md). Each
//  packet is four little-endian float32 — the rotation vector quaternion x, y, z, w mapping the
//  device frame into Android's East-North-Up world frame — plus an int64 sensor timestamp we
//  currently ignore: orientation is a "current value", and the newest packet always wins.
//
//  Nothing here renders or converts anything. The twin view pulls `latest` on its own render
//  clock; this thread just keeps that value fresh at the agent's 50 Hz.
//

import Foundation
import simd

final class SensorStream {
    private let socket: TCPSocket
    private var thread: Thread?
    private var stopping = false

    private let lock = NSLock()
    private var latestQuat: simd_quatf?
    private var packets = 0

    /// The newest device orientation, or nil before the first packet (or on a device with no
    /// rotation vector sensor — the channel simply stays silent). Any thread.
    var latest: simd_quatf? {
        lock.lock(); defer { lock.unlock() }
        return latestQuat
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
            guard let data = try? socket.readFully(24) else { break }
            let q: simd_quatf = data.withUnsafeBytes { raw in
                simd_quatf(ix: raw.loadUnaligned(fromByteOffset: 0, as: Float32.self),
                           iy: raw.loadUnaligned(fromByteOffset: 4, as: Float32.self),
                           iz: raw.loadUnaligned(fromByteOffset: 8, as: Float32.self),
                           r: raw.loadUnaligned(fromByteOffset: 12, as: Float32.self))
            }
            guard q.length > 0.5 else { continue }   // malformed or all-zero packet
            lock.lock()
            latestQuat = simd_normalize(q)
            packets += 1
            lock.unlock()
        }
        AppBuild.log("sensor stream ended")
    }
}
