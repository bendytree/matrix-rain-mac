import ScreenCaptureKit
import SwiftUI

class VisorAppManager: ObservableObject {
    init() {
        checkScreenRecordingPermission()
    }

    func checkScreenRecordingPermission() {
        Task {
            do {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {}
        }
    }
}

@main
struct VisorApp: App {
    @StateObject private var appManager = VisorAppManager()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
        } label: {
            // Katakana glyph for a "Matrix digital rain" look in the menu bar.
            Text(verbatim: "ﾑ")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
        }
    }
}
