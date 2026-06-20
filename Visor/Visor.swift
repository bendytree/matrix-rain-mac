import AppKit
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
            Image(nsImage: VisorApp.menuIcon)
        }
    }

    /// "Matrix digital rain" menu-bar glyph: dashed vertical streaks (stacked glyphs) each with a
    /// solid leading "head" at the bottom. Template image so it tints with the menu bar.
    private static let menuIcon: NSImage = {
        let w: CGFloat = 18, h: CGFloat = 16
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        NSColor.black.setStroke(); NSColor.black.setFill()
        let lw = max(1.0, h * 0.085)
        // (x, top-offset, length) as fractions; origin is bottom-left so y is flipped from "top".
        let cols: [(x: CGFloat, top: CGFloat, len: CGFloat)] = [
            (0.16, 0.05, 0.62), (0.40, 0.32, 0.58), (0.62, 0.00, 0.46), (0.85, 0.40, 0.55),
        ]
        for c in cols {
            let x = c.x * w
            let yTop = h - c.top * h
            let yBot = h - min(1.0, c.top + c.len) * h
            let p = NSBezierPath()
            p.lineWidth = lw
            p.lineCapStyle = .round
            p.setLineDash([lw * 1.3, lw * 0.95], count: 2, phase: 0)   // dashes = stacked glyphs
            p.move(to: NSPoint(x: x, y: yTop))
            p.line(to: NSPoint(x: x, y: yBot + lw * 1.6))
            p.stroke()
            let head = lw * 1.5                                         // solid leading glyph
            NSBezierPath(rect: NSRect(x: x - head / 2, y: yBot, width: head, height: head)).fill()
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }()
}
