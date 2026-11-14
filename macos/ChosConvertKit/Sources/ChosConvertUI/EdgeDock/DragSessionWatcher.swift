import AppKit
import Foundation

/// What the watcher needs to know about the system, abstracted so the state machine is testable.
@MainActor
protocol DragSignals {
    /// Whether the primary mouse button is currently down (`NSEvent.pressedMouseButtons`).
    var isPrimaryButtonDown: Bool { get }
    /// `NSPasteboard(name: .drag).changeCount`: increments whenever any app starts a drag.
    var dragChangeCount: Int { get }
    /// Whether the drag pasteboard advertises file URLs. Only the type list is read, never the
    /// contents, until the user actually drags onto the dock.
    var dragCarriesFiles: Bool { get }
}

@MainActor
struct SystemDragSignals: DragSignals {
    private let pasteboard = NSPasteboard(name: .drag)
    var isPrimaryButtonDown: Bool { NSEvent.pressedMouseButtons & 1 != 0 }
    var dragChangeCount: Int { pasteboard.changeCount }
    var dragCarriesFiles: Bool { pasteboard.types?.contains(.fileURL) ?? false }
}

/// Detects system-wide file drag sessions **without** Accessibility permission or global event
/// monitors: it samples the mouse button state and, only while the button is down, the drag
/// pasteboard's change count. A change count that moved since the last button release, while the
/// button is held, means another app (or Finder) just started a drag. The session ends when the
/// button is released.
@MainActor
final class DragSessionWatcher {
    enum Event: Equatable { case began, ended }

    /// Sampling interval. 120 ms keeps the strip appearing before the pointer can travel to the
    /// screen edge, while costing a handful of cheap calls per second.
    static let interval: Duration = .milliseconds(120)

    var onEvent: ((Event) -> Void)?
    private(set) var isDragging = false
    private var signals: any DragSignals
    private var lastChangeCount: Int
    private var wasButtonDown = false
    private var loop: Task<Void, Never>?

    init(signals: any DragSignals = SystemDragSignals()) {
        self.signals = signals
        lastChangeCount = signals.dragChangeCount
    }

    func start() {
        guard loop == nil else { return }
        lastChangeCount = signals.dragChangeCount
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval, tolerance: .milliseconds(40))
                self?.tick()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        if isDragging {
            isDragging = false
            onEvent?(.ended)
        }
    }

    /// One sample. Internal so tests can drive the state machine deterministically.
    func tick() {
        let down = signals.isPrimaryButtonDown
        defer { wasButtonDown = down }
        if isDragging {
            if !down {
                isDragging = false
                lastChangeCount = signals.dragChangeCount
                onEvent?(.ended)
            }
            return
        }
        guard down else {
            // Absorb drags that started and ended between two samples, so the next ordinary click
            // isn't mistaken for a drag. One read per click; nothing is read while idle.
            if wasButtonDown { lastChangeCount = signals.dragChangeCount }
            return
        }
        let count = signals.dragChangeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if signals.dragCarriesFiles {
            isDragging = true
            onEvent?(.began)
        }
    }
}
