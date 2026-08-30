//
//  Palette.swift
//  The window's fixed colours.
//
//  Literal sRGB, deliberately, and this is the whole reason the file exists. AppKit's semantic
//  colours — windowBackgroundColor, textBackgroundColor, controlBackgroundColor — each carry an
//  inactive variant, and macOS tints them differently when the window loses key. Three panes
//  reaching for three different semantic colours therefore drift apart the moment you click
//  another app: the sidebar and inspector went visibly warm while the canvas stayed white.
//
//  Values measured off Device Hub by ~/rplay-hub, which pins them for the same reason.
//
//  The cost is that these do not follow Dark Mode. That is the same trade ~/rplay-hub makes —
//  Device Hub itself is a light-only window, and matching it is the point.
//

import AppKit

enum Palette {
    /// The side panes: sidebar and inspector.
    static let pane = NSColor(srgbRed: 0xFA / 255, green: 0xFA / 255, blue: 0xFA / 255, alpha: 1)
    /// The middle column, behind the picture and its button strip.
    static let canvas = NSColor.white
    /// Hairlines between list rows. Literal for the same reason as the rest: NSColor.separatorColor
    /// is semantic and shifts with focus, which on a hairline reads as flicker.
    static let separator = NSColor(srgbRed: 0xE3 / 255, green: 0xE3 / 255, blue: 0xE3 / 255,
                                   alpha: 1)
}
