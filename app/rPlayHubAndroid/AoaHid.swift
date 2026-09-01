//
//  AoaHid.swift
//  scrcpy-style HID input over the Android Open Accessory (AOA) protocol, on USB.
//
//  Parity with scrcpy's --keyboard=aoa / --mouse=aoa: register a real USB HID keyboard and mouse
//  ON THE PHONE, over the USB control endpoint, and stream HID reports. The phone sees physical
//  input devices, so it works where InputManager injection is blocked (some games, DRM) and the
//  on-screen keyboard stays hidden while a HID keyboard is attached.
//
//  Crucially — and unlike a full AOA accessory — we DO NOT send ACCESSORY_START, so the device is
//  never re-enumerated into accessory mode: it stays an ordinary adb device and the agent's
//  mirroring keeps running. Only the HID vendor requests (GET_PROTOCOL / REGISTER_HID /
//  SET_HID_REPORT_DESC / SEND_HID_EVENT) are used, exactly as scrcpy does.
//
//  USB-only: AOA rides the physical USB link, so this does nothing for a network (Tailscale)
//  device. IOKit (IOUSBHost) is used directly — no libusb dependency — so it can live in the
//  sandboxed App Store build (com.apple.security.device.usb).
//
//  NOTE: runtime-untested in the session it was written (no USB device was attached); the AOA
//  sequence and HID descriptors follow scrcpy's, which are proven. Validate on a USB phone.
//

import Foundation
import IOKit
import IOUSBHost

enum AoaHidError: Error, CustomStringConvertible {
    case deviceNotFound(String)
    case openFailed(String)
    case protocolUnsupported(Int)
    case requestFailed(String)

    var description: String {
        switch self {
        case .deviceNotFound(let s): return "no USB device with serial \(s) (is the phone on USB?)"
        case .openFailed(let s): return "cannot open the USB device: \(s)"
        case .protocolUnsupported(let v): return "the device's AOA protocol is \(v); HID needs 2+"
        case .requestFailed(let s): return "USB control request failed: \(s)"
        }
    }
}

/// One AOA HID session against a USB-attached device. Registers a keyboard and a mouse, then
/// sends reports. Not thread-safe; drive it from one queue.
final class AoaHid {
    // AOA vendor requests (Android f_accessory.h).
    private static let getProtocol: UInt8 = 51
    private static let registerHid: UInt8 = 54
    private static let unregisterHid: UInt8 = 55
    private static let setHidReportDesc: UInt8 = 56
    private static let sendHidEvent: UInt8 = 57
    // bmRequestType: vendor, device recipient.
    private static let out: UInt8 = 0x40   // host -> device
    private static let inn: UInt8 = 0xC0   // device -> host

    // Accessory ids for our two HID devices.
    private static let keyboardId: UInt16 = 1
    private static let mouseId: UInt16 = 2

    private let device: IOUSBHostDevice
    let serial: String

    /// Open the USB device whose USB serial matches `serial` (the adb serial for a USB device),
    /// verify AOA v2+, and register the keyboard and mouse HID devices.
    init(serial: String) throws {
        self.serial = serial
        guard let service = AoaHid.matchingService(serial: serial) else {
            throw AoaHidError.deviceNotFound(serial)
        }
        defer { IOObjectRelease(service) }
        do {
            device = try IOUSBHostDevice(__ioService: service, options: [], queue: nil,
                                         interestHandler: nil)
        } catch {
            throw AoaHidError.openFailed("\(error)")
        }
        let proto = try protocolVersion()
        guard proto >= 2 else { throw AoaHidError.protocolUnsupported(proto) }
        try register(id: AoaHid.keyboardId, descriptor: AoaHid.keyboardDescriptor)
        try register(id: AoaHid.mouseId, descriptor: AoaHid.mouseDescriptor)
    }

    deinit {
        try? controlOut(AoaHid.unregisterHid, value: AoaHid.keyboardId, index: 0, data: nil)
        try? controlOut(AoaHid.unregisterHid, value: AoaHid.mouseId, index: 0, data: nil)
    }

    // MARK: - keyboard / mouse reports

    /// An 8-byte boot-keyboard report: modifier bitmask + up to six HID usage codes (0 = none).
    func sendKeyboard(modifiers: UInt8, keys: [UInt8]) throws {
        var report = [UInt8](repeating: 0, count: 8)
        report[0] = modifiers
        for (i, k) in keys.prefix(6).enumerated() { report[2 + i] = k }
        try controlOut(AoaHid.sendHidEvent, value: AoaHid.keyboardId, index: 0, data: Data(report))
    }

    /// Release all keys.
    func releaseKeyboard() throws {
        try controlOut(AoaHid.sendHidEvent, value: AoaHid.keyboardId, index: 0,
                       data: Data(repeating: 0, count: 8))
    }

    /// A 4-byte relative-mouse report: button bitmask, dx, dy, wheel (each -127..127).
    func sendMouse(buttons: UInt8, dx: Int8, dy: Int8, wheel: Int8) throws {
        let report: [UInt8] = [buttons, UInt8(bitPattern: dx), UInt8(bitPattern: dy),
                               UInt8(bitPattern: wheel)]
        try controlOut(AoaHid.sendHidEvent, value: AoaHid.mouseId, index: 0, data: Data(report))
    }

    // MARK: - AOA plumbing

    private func protocolVersion() throws -> Int {
        let data = NSMutableData(length: 2)!
        var moved: UInt = 0
        var req = IOUSBDeviceRequest(bmRequestType: AoaHid.inn, bRequest: AoaHid.getProtocol,
                                     wValue: 0, wIndex: 0, wLength: 2)
        do {
            try device.__send(req, data: data, bytesTransferred: &moved,
                                         completionTimeout: 1.0)
        } catch {
            throw AoaHidError.requestFailed("GET_PROTOCOL: \(error)")
        }
        let bytes = data.bytes.assumingMemoryBound(to: UInt8.self)
        return Int(bytes[0]) | (Int(bytes[1]) << 8)
    }

    private func register(id: UInt16, descriptor: [UInt8]) throws {
        // REGISTER_HID: wIndex carries the descriptor's total length, no data.
        try controlOut(AoaHid.registerHid, value: id, index: UInt16(descriptor.count), data: nil)
        // SET_HID_REPORT_DESC: the descriptor bytes (small enough to send in one transfer).
        try controlOut(AoaHid.setHidReportDesc, value: id, index: 0, data: Data(descriptor))
    }

    private func controlOut(_ request: UInt8, value: UInt16, index: UInt16, data: Data?) throws {
        let payload = data ?? Data()
        let nsdata = payload.isEmpty ? nil : NSMutableData(data: payload)
        var moved: UInt = 0
        var req = IOUSBDeviceRequest(bmRequestType: AoaHid.out, bRequest: request,
                                     wValue: value, wIndex: index, wLength: UInt16(payload.count))
        do {
            try device.__send(req, data: nsdata, bytesTransferred: &moved,
                                         completionTimeout: 1.0)
        } catch {
            throw AoaHidError.requestFailed("request \(request): \(error)")
        }
    }

    // MARK: - device discovery

    /// The IOUSBHostDevice io_service whose "USB Serial Number" equals `serial`. Caller releases.
    private static func matchingService(serial: String) -> io_service_t? {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            if let sn = IORegistryEntryCreateCFProperty(service, "USB Serial Number" as CFString,
                                                        kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String, sn == serial {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    // MARK: - HID report descriptors (scrcpy's)

    /// Boot keyboard: 8-byte report [modifiers, reserved, key1..key6].
    private static let keyboardDescriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
        0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
        0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02,
        0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
        0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65,
        0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
        0xC0,
    ]

    /// Relative mouse: 4-byte report [buttons, dx, dy, wheel].
    private static let mouseDescriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,
        0x09, 0x01, 0xA1, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x05, 0x15, 0x00, 0x25, 0x01,
        0x95, 0x05, 0x75, 0x01, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x03, 0x81, 0x01,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38,
        0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
        0xC0, 0xC0,
    ]
}
