import ScreenCaptureKit
import SwiftUI

/// The app's configuration user interface.
struct ConfigurationView: View {
    @ObservedObject var screenRecorder: ScreenRecorder

    var body: some View {
        Text("Matrix")
        Divider()
        Button("Settings") { showMatrixSettings() }
        Button("Turn On") {
            Task {
                await screenRecorder.monitorAvailableContent()
                guard let display = screenRecorder.selectedDisplay else { return }
                let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: display.width, height: display.height)
                screenRecorder.panelManager.presentPanel(content: { screenRecorder.capturePreview }, contentRect: frame)
                await screenRecorder.start()
            }
        }
        .disabled(screenRecorder.isRunning)
        Button("Turn Off") {
            Task {
                await screenRecorder.stop()
                screenRecorder.panelManager.dismissPanel()
            }
        }
        .disabled(!screenRecorder.isRunning)
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }

    func showMatrixSettings() {
        let view = MatrixSettingsView(params: screenRecorder.capturePreview.metalView.params)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 620),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Matrix Settings"
        window.level = .popUpMenu             // above the full-screen overlay
        window.isReleasedWhenClosed = false
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

struct MatrixSettingsView: View {
    @ObservedObject var params: MatrixParams

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show rain mask (pink)", isOn: $params.maskDebug)
            row("Frame rate", $params.fps, 1...60)
            Divider()
            Toggle(isOn: $params.rainOn) { Text("Rain").bold() }
            Group {
                row("Flat threshold", $params.flatThreshold, 0.005...0.2)
                row("Mask detail (px)", $params.maskCell, 6...80)
                row("Rain glyph size", $params.cellSize, 10...110)
                row("Rain opacity", $params.rainOpacity, 0...1)
                row("Rain density", $params.rainDensity, 0...12)
                row("Trail length", $params.trailLength, 4...100)
                row("Cursor clear", $params.cursorClear, 0...700)
                row("Rain speed", $params.rainSpeed, 0.05...2)
                row("Glyph churn", $params.glyphChurn, 0...30)
            }
            .disabled(!params.rainOn)
            Divider()
            row("Scanlines", $params.scanlineStrength, 0...0.5)
            Toggle(isOn: $params.glowOn) { Text("Glow").bold() }
            row("Glow strength", $params.glow, 0...1.5).disabled(!params.glowOn)
            row("Curvature", $params.curvature, 0...0.25)
            row("Contrast", $params.contrast, 0.5...2.5)
            row("Roll bar", $params.barSpeed, 0...1)
        }
        .padding()
        .frame(width: 340)
    }

    private func row(_ label: String, _ value: Binding<Float>, _ range: ClosedRange<Float>) -> some View {
        HStack {
            Text(label).frame(width: 105, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.3f", value.wrappedValue))
                .frame(width: 48, alignment: .trailing)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}