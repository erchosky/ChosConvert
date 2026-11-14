import AppKit
import ChosConvertKit
import SwiftUI

/// The per-display Edge Dock window: a borderless, **non-activating** panel. Clicking or dropping
/// on it never activates ChosConvert or steals focus from the app the user is dragging from.
final class EdgeDockPanel: NSPanel {
    let screenID: String

    init(screenID: String) {
        self.screenID = screenID
        super.init(contentRect: CGRect(x: 0, y: 0, width: 4, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        // Above normal and floating windows (and the auto-hidden menu bar of full-screen apps).
        level = .statusBar
        // Present on every Space (including full-screen Spaces when allowed), never moved by
        // Mission Control, never part of ⌘` window cycling.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Explicitly false: transparent areas must still receive drags.
        ignoresMouseEvents = false
        isMovable = false
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        setAccessibilityLabel(L.s("dock.a11y.panel"))
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that reacts to the first click in a non-key panel (buttons, result drag-out).
final class EdgeDockHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Receives the drag for the whole panel (AppKit `NSDraggingDestination`) and forwards it to the
/// controller, which hit-tests the SwiftUI targets. Keeping a single destination avoids enter/exit
/// churn between nested SwiftUI drop zones while the panel grows and shrinks.
final class EdgeDockDropView: NSView {
    let screenID: String
    weak var controller: EdgeDockController?
    let hostingView: NSView

    init(screenID: String, hostingView: NSView) {
        self.screenID = screenID
        self.hostingView = hostingView
        super.init(frame: .zero)
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
        // Only this view is a destination; SwiftUI must not claim the drag first.
        hostingView.unregisterDraggedTypes()
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    static func fileURLs(_ info: any NSDraggingInfo) -> [URL] {
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    /// Drag location in the SwiftUI root's (flipped) coordinate space.
    private func swiftUIPoint(_ info: any NSDraggingInfo) -> CGPoint {
        hostingView.convert(info.draggingLocation, from: nil)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let controller else { return [] }
        let urls = Self.fileURLs(sender)
        guard !urls.isEmpty, controller.accepts(fromOwnApp: sender.draggingSource != nil) else { return [] }
        controller.dragEntered(screenID: screenID, urls: urls, screenPoint: NSEvent.mouseLocation)
        return controller.dragMoved(screenID: screenID, point: swiftUIPoint(sender))
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        controller?.dragMoved(screenID: screenID, point: swiftUIPoint(sender)) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        controller?.dragExited(screenID: screenID)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        controller?.performDrop(screenID: screenID, urls: Self.fileURLs(sender), point: swiftUIPoint(sender)) ?? false
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { false }
}
