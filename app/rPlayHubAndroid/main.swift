//
//  main.swift
//  rPlayHubAndroid — mirror and control an Android device over Google's own screen-sharing agent.
//
//  Explicit bootstrap rather than @NSApplicationMain so the app works identically whether it is
//  launched from an .app bundle or straight from the build directory during development.
//

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
