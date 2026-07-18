import AppKit
import SwiftUI

VFFontRegistrar.registerIfNeeded()

// Dev utility: render the settings window to PNGs (light + dark) without
// launching the full app. Usage: "Whisper Smart" --render-settings-snapshot /tmp/ws
if let flagIndex = CommandLine.arguments.firstIndex(of: "--render-settings-snapshot"),
   CommandLine.arguments.count > flagIndex + 1 {
    let basePath = CommandLine.arguments[flagIndex + 1]
    let snapshotApp = NSApplication.shared
    snapshotApp.setActivationPolicy(.accessory)
    ProductOnboardingPreferences.markCompleted()

    for tab in ["general", "hotkey", "provider", "history"] {
    for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let view = NSHostingView(rootView: SettingsView(initialTabRawValue: tab))
        view.frame = NSRect(x: 0, y: 0, width: VFSize.settingsWidth, height: VFSize.settingsHeight)
        view.appearance = NSAppearance(named: appearanceName)

        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearanceName)
        window.contentView = view
        view.layoutSubtreeIfNeeded()

        // Give SwiftUI async layout passes a chance to settle.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "\(basePath)-\(tab)-\(suffix).png"))
        }
    }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
