import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

/// The app's configuration user interface.
struct ConfigurationView: View {
    private let alignmentOffset: CGFloat = 10

    @ObservedObject var screenRecorder: ScreenRecorder
    @State var shaderPath: String = "../shaders/invert.metal"
    @State private var showingSettings = false

    var body: some View {
        Button("Settings") { showSettings() }
            .disabled(screenRecorder.isRunning)
        Button("Select Shader") { selectShader() }
            .disabled(screenRecorder.isRunning)
        Button("Matrix Settings…") { showMatrixSettings() }
        Button("Visor Down") {
            Task {
                await screenRecorder.monitorAvailableContent()
                guard let display = screenRecorder.selectedDisplay else { return }
                let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: display.width, height: display.height)
                screenRecorder.panelManager.presentPanel(content: { screenRecorder.capturePreview }, contentRect: frame)
                await screenRecorder.start()
            }
        }
        .disabled(screenRecorder.isRunning)

        Button {
            Task { await screenRecorder.stop()
                screenRecorder.panelManager.dismissPanel()
            }

        } label: {
            Text("Visor Up")
        }
        .disabled(!screenRecorder.isRunning)
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }

    func selectShader() {
        let dialog = NSOpenPanel()

        dialog.title = "Choose a shader file"
        dialog.showsResizeIndicator = true
        dialog.showsHiddenFiles = false
        dialog.canChooseDirectories = false
        dialog.canCreateDirectories = true
        dialog.allowsMultipleSelection = false
        NSApplication.shared.activate(ignoringOtherApps: true)
        dialog.makeKey()
        dialog.allowedContentTypes = [UTType(filenameExtension: "metal")!]

        if dialog.runModal() == NSApplication.ModalResponse.OK {
            guard let result = dialog.url else { return }
            shaderPath = result.path
            screenRecorder.capturePreview.metalView.updateShader(shaderPath: shaderPath)
        } else {
            return
        }
    }

    func showMatrixSettings() {
        let view = MatrixSettingsView(params: screenRecorder.capturePreview.metalView.params)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 590),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Matrix Settings"
        window.level = .popUpMenu             // above the full-screen overlay
        window.isReleasedWhenClosed = false
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        let settingsView = SettingsView(inputNumber: $screenRecorder.topSpace)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.level = .floating
        window.isReleasedWhenClosed = false

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.contentView = NSHostingView(rootView: settingsView)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

struct MatrixSettingsView: View {
    @ObservedObject var params: MatrixParams

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show rain mask (pink)", isOn: $params.maskDebug)
            Toggle("Rain enabled", isOn: $params.rainOn)
            Divider()
            row("Flat threshold", $params.flatThreshold, 0.005...0.2)
            row("Mask detail (px)", $params.maskCell, 6...80)
            row("Rain glyph size", $params.cellSize, 10...110)
            Divider()
            row("Rain opacity", $params.rainOpacity, 0...1)
            row("Rain density", $params.rainDensity, 0...12)
            row("Trail length", $params.trailLength, 4...100)
            row("Cursor clear", $params.cursorClear, 0...700)
            row("Rain speed", $params.rainSpeed, 0.05...2)
            row("Glyph churn", $params.glyphChurn, 0...30)
            Divider()
            row("Scanlines", $params.scanlineStrength, 0...0.5)
            row("Glow", $params.glow, 0...1.5)
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

struct SettingsView: View {
    @Binding var inputNumber: Int
    let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    var body: some View {
        VStack {
            HStack {
                Text("Top Spacing:")
                TextField("Number", value: $inputNumber, formatter: formatter)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()
            }
            Button("Save") {
                NSApplication.shared.windows.last?.close()
            }
            .padding()
        }
        .padding()
    }
}
