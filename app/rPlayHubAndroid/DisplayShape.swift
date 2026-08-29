//
//  DisplayShape.swift
//  The physical shape of the device's screen — rounded corners and the camera cutout.
//
//  Asked of the device rather than kept in a table. ~/rplay-hub has to hard-code per-model
//  geometry because iOS never tells you: `DeviceModel.swift` carries a corner fraction measured
//  off Apple's framebuffer masks and a notch rectangle per identifier. Android simply reports it,
//  so there is no table to get wrong and no unknown-device fallback to apologise for.
//
//  Why mask at all: the framebuffer allocates the pixels behind a punch-hole camera and the agent
//  streams them, but the physical display has a hole there. Painting over it is what makes the
//  mirror read as a phone rather than as a rectangle of video — the same reason the iOS side
//  paints out a notch. (It deliberately does NOT paint a Dynamic Island, because the display
//  really does extend behind that one and iOS draws it black itself. A punch hole is the notch
//  case: there is no display under it.)
//
//  Everything here is in the display's own pixels, in its canonical orientation.
//

import CoreGraphics
import Foundation

struct DisplayShape: Equatable {
    /// Corner radius in display pixels. Zero for a square-cornered display.
    var cornerRadius: CGFloat = 0
    var cutout: Cutout?
    /// The display size these coordinates belong to, so the view can scale them.
    var displaySize: CGSize = .zero

    enum Cutout: Equatable {
        /// A punch-hole camera.
        case circle(center: CGPoint, radius: CGFloat)
        /// Anything we could not parse precisely — the system's own bounding box, drawn as a
        /// capsule. Rounder than a rectangle and closer to every real cutout than nothing.
        case capsule(CGRect)
    }

    /// Read the shape out of `dumpsys display`. Nil when the device does not report one, which
    /// is normal for emulators and square displays.
    static func query(serial: String) -> DisplayShape? {
        guard let dump = try? Adb.shell(serial, "dumpsys display") else { return nil }
        // The built-in panel is the first DisplayDeviceInfo; a connected display would follow.
        guard let info = dump.components(separatedBy: "DisplayDeviceInfo{").dropFirst().first
        else { return nil }

        var shape = DisplayShape()
        shape.displaySize = parseDisplaySize(info) ?? .zero
        shape.cornerRadius = parseCornerRadius(info) ?? 0
        shape.cutout = parseCutout(info)
        guard shape.cornerRadius > 0 || shape.cutout != nil else { return nil }
        return shape
    }

    // MARK: - parsing
    //
    // Text scraping, and it is the right tool here: the alternative is the control channel's
    // DisplayConfigurationRequest, which carries no cutout at all. Everything below degrades to
    // nil rather than to a wrong shape, because a wrong mask hides real pixels.

    private static func parseDisplaySize(_ s: String) -> CGSize? {
        // ...displayWidth=1080 displayHeight=2424...
        guard let w = number(after: "displayWidth=", in: s),
              let h = number(after: "displayHeight=", in: s), w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// roundedCorners RoundedCorners{[RoundedCorner{position=TopLeft, radius=115, ...
    private static func parseCornerRadius(_ s: String) -> CGFloat? {
        guard let range = s.range(of: "roundedCorners RoundedCorners{") else { return nil }
        let tail = s[range.upperBound...]
        guard let end = tail.range(of: "}}") else { return nil }
        return number(after: "radius=", in: String(tail[..<end.lowerBound]))
    }

    /// The cutout comes as an SVG-ish path in `cutoutSpec={...}`. Google's punch-hole spec is
    /// always the same two-arc circle:
    ///
    ///     m 581.5,86 a 41.5,41.5 0 0 0 -83,0 41.5,41.5 0 0 0 83,0 z @left
    ///
    /// which is a circle of radius 41.5 centred at (581.5 - 41.5, 86). Rather than write a path
    /// parser for a language we only ever see one sentence of, match that shape and fall back to
    /// the bounding box the system already computed for anything else.
    private static func parseCutout(_ s: String) -> Cutout? {
        if let spec = between("cutoutSpec={", "}", in: s), !spec.isEmpty {
            if let circle = parseCircleSpec(spec) { return circle }
        }
        // boundingRect={Bounds=[Rect(0, 0 - 0, 0), Rect(484, 0 - 596, 152), ...]}
        if let bounds = between("boundingRect={Bounds=[", "]}", in: s) {
            for rect in bounds.components(separatedBy: "Rect(").dropFirst() {
                guard let r = parseRect(rect), r.width > 0, r.height > 0 else { continue }
                return .capsule(r)
            }
        }
        return nil
    }

    private static func parseCircleSpec(_ spec: String) -> Cutout? {
        // "m <x>,<y> a <r>,<r> ..." — require both, and require the arc to be circular.
        guard let m = spec.range(of: "m "), let a = spec.range(of: "a ") , m.lowerBound < a.lowerBound
        else { return nil }
        let movePart = spec[m.upperBound..<a.lowerBound].trimmingCharacters(in: .whitespaces)
        let moveNumbers = movePart.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard moveNumbers.count >= 2 else { return nil }

        let arcPart = spec[a.upperBound...].prefix(40)
        let arcNumbers = arcPart.split(whereSeparator: { $0 == "," || $0 == " " })
            .compactMap { Double($0) }
        guard arcNumbers.count >= 2, arcNumbers[0] > 0, arcNumbers[0] == arcNumbers[1] else {
            return nil
        }
        let r = CGFloat(arcNumbers[0])
        return .circle(center: CGPoint(x: CGFloat(moveNumbers[0]) - r, y: CGFloat(moveNumbers[1])),
                       radius: r)
    }

    private static func parseRect(_ s: String) -> CGRect? {
        // "484, 0 - 596, 152), ..." — left, top - right, bottom
        guard let close = s.firstIndex(of: ")") else { return nil }
        let body = s[..<close].replacingOccurrences(of: "-", with: ",")
        let n = body.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard n.count == 4 else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1])
    }

    private static func between(_ open: String, _ close: String, in s: String) -> String? {
        guard let a = s.range(of: open) else { return nil }
        let tail = s[a.upperBound...]
        guard let b = tail.range(of: close) else { return nil }
        return String(tail[..<b.lowerBound])
    }

    private static func number(after key: String, in s: String) -> CGFloat? {
        guard let r = s.range(of: key) else { return nil }
        let digits = s[r.upperBound...].prefix { $0.isNumber || $0 == "." }
        return Double(digits).map { CGFloat($0) }
    }
}
