import SwiftUI
 
/// An NSPanel subclass that implements floating panel traits.
class FloatingPanel<Content: View>: NSPanel {
    init(view: () -> Content,
         contentRect: NSRect,
         backing: NSWindow.BackingStoreType = .buffered,
         defer flag: Bool = false)
    {
        /// Init the window as usual
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .closable, .borderless],
                   backing: backing,
                   defer: flag)

        isFloatingPanel = true
        // Sit just above the menu bar so the whole screen (incl. the menu bar) is covered.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        animationBehavior = .utilityWindow
        backgroundColor = .clear
        // Hide the overlay from screen capture so the shader never captures its own
        // output (which would create a runaway feedback "wormhole").
        sharingType = .none
        
        /// Set the content view.
        /// The safe area is ignored because the title bar still interferes with the geometry
        contentView = NSHostingView(rootView: view()
            .frame(minWidth: 0,
                   maxWidth: .infinity,
                   minHeight: 0,
                   maxHeight: .infinity,
                   alignment: .topLeading)
            .ignoresSafeArea())
    }
}

class FloatingPanelManager<PanelContent: View>: ObservableObject {
    @Published var isPresented: Bool = false
    
    private var panel: FloatingPanel<PanelContent>?
    
    func presentPanel(content: () -> PanelContent, contentRect: CGRect) {
        if panel == nil {
            panel = FloatingPanel(view: content, contentRect: contentRect)
        }
        panel?.setFrame(contentRect, display: true)
        panel?.setIsVisible(true)
        isPresented = true
    }
    
    func dismissPanel() {
        panel?.setIsVisible(false)
        isPresented = false
    }
}
