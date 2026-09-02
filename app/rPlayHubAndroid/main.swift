//
//  main.swift
//  rPlayHubAndroid — mirror and control an Android device over Google's own screen-sharing agent.
//
//  Explicit bootstrap rather than @NSApplicationMain so the app works identically whether it is
//  launched from an .app bundle or straight from the build directory during development.
//

import AppKit
import Darwin

// Writing to a socket whose peer has gone raises SIGPIPE, whose default action is to KILL the
// process — the app vanished with exit 141 and no crash report the moment a device session was
// torn down. Every socket here (adb, the agent's channels, the legacy agent, the emulator
// bridge) can have its far end disappear at any moment, so the signal is ignored once for the
// whole process and those writes fail with EPIPE like any other error. This was previously done
// inside EmulatorSession, which only helped when an emulator happened to be hosted.
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
