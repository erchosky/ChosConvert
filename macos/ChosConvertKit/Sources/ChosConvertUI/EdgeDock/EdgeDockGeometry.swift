import AppKit
import ChosConvertKit
import CoreGraphics

/// A display as the Edge Dock sees it. Frames are in AppKit global coordinates (points, origin at
/// the bottom-left of the primary display), so displays with different scale factors share one
/// coordinate space and need no conversion.
struct DockScreen: Hashable, Sendable {
    /// Stable display UUID (survives reboots and re-plugging), or the display ID as a fallback.
    var id: String
    var displayID: CGDirectDisplayID
    var name: String
    var frame: CGRect
    var visibleFrame: CGRect
    var scale: CGFloat
    /// Holds the menu bar (`NSScreen.screens.first`).
    var isMain: Bool
}

extension DockScreen {
    @MainActor init?(_ screen: NSScreen, isMain: Bool) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        var uuidString = "\(displayID)"
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            uuidString = (CFUUIDCreateString(nil, uuid) as String?) ?? uuidString
        }
        self.init(id: uuidString, displayID: displayID, name: screen.localizedName, frame: screen.frame,
                  visibleFrame: screen.visibleFrame, scale: screen.backingScaleFactor, isMain: isMain)
    }

    @MainActor static func current() -> [DockScreen] {
        NSScreen.screens.enumerated().compactMap { DockScreen($0.element, isMain: $0.offset == 0) }
    }
}

/// Pure layout rules for the Edge Dock. No AppKit state, so they are unit-tested with synthetic
/// multi-monitor arrangements (mixed scale factors, offset heights, vertical stacks).
enum EdgeDockGeometry {
    /// Expanded panel size.
    static let panelWidth: CGFloat = 300
    static let panelMaxHeight: CGFloat = 480
    /// Space between the panel and the screen edge / top and bottom of the visible area.
    static let panelInset: CGFloat = 8
    /// Edge segments shorter than this are not worth a strip (too hard to hit).
    static let minimumSegment: CGFloat = 160
    /// Tolerance when deciding whether two displays touch (arrangements are not always pixel-exact).
    static let adjacencyTolerance: CGFloat = 2

    /// Screens that should show a strip for the given preference.
    static func screens(for choice: EdgeDockScreenChoice, in screens: [DockScreen]) -> [DockScreen] {
        switch choice {
        case .all:
            return screens
        case .main:
            return screens.filter(\.isMain)
        case .display(let id):
            let match = screens.filter { $0.id == id }
            // A remembered display that is unplugged falls back to the main display, so the dock
            // never silently disappears.
            return match.isEmpty ? screens.filter(\.isMain) : match
        }
    }

    /// The part of `screen`'s edge on `side` that is not shared with a neighbouring display.
    /// Returns the longest free vertical range, or nil when the edge is fully interior (the
    /// pointer would just cross into the next display, so a strip there can't be "hit").
    static func outerSegment(of screen: DockScreen, side: EdgeDockSide, among screens: [DockScreen]) -> ClosedRange<CGFloat>? {
        let area = screen.visibleFrame
        let edgeX = side == .right ? screen.frame.maxX : screen.frame.minX
        var free: [ClosedRange<CGFloat>] = [area.minY...area.maxY]
        for other in screens where other.id != screen.id {
            let touches = side == .right
                ? abs(other.frame.minX - edgeX) <= adjacencyTolerance
                : abs(other.frame.maxX - edgeX) <= adjacencyTolerance
            guard touches else { continue }
            free = free.flatMap { subtract(other.frame.minY...other.frame.maxY, from: $0) }
        }
        let best = free.max { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }
        guard let best, best.upperBound - best.lowerBound >= minimumSegment else { return nil }
        return best
    }

    static func subtract(_ cut: ClosedRange<CGFloat>, from range: ClosedRange<CGFloat>) -> [ClosedRange<CGFloat>] {
        guard cut.overlaps(range) else { return [range] }
        var out: [ClosedRange<CGFloat>] = []
        if cut.lowerBound > range.lowerBound { out.append(range.lowerBound...cut.lowerBound) }
        if cut.upperBound < range.upperBound { out.append(cut.upperBound...range.upperBound) }
        return out
    }

    /// The thin strip window frame. It hugs the visible frame's edge: when the macOS Dock sits on
    /// the same side, the strip sits beside it so dropping onto Dock icons keeps working.
    static func stripFrame(for screen: DockScreen, side: EdgeDockSide, width: CGFloat, among screens: [DockScreen]) -> CGRect? {
        guard let segment = outerSegment(of: screen, side: side, among: screens) else { return nil }
        let area = screen.visibleFrame
        let w = max(1, min(width, 40))
        let x = side == .right ? area.maxX - w : area.minX
        return CGRect(x: x, y: segment.lowerBound, width: w, height: segment.upperBound - segment.lowerBound)
            .integral
    }

    /// The expanded panel window frame: attached to the same edge, vertically centred on the
    /// pointer and clamped inside the visible area. The window reaches all the way to the edge
    /// (the card is drawn `panelInset` away from it) so the pointer, which entered at the very
    /// edge, is still inside the window after it expands — otherwise it would collapse at once.
    static func panelFrame(for screen: DockScreen, side: EdgeDockSide, anchorY: CGFloat, height: CGFloat) -> CGRect {
        let area = screen.visibleFrame.insetBy(dx: 0, dy: panelInset)
        let h = min(max(height, 80), min(panelMaxHeight, area.height))
        let w = min(panelWidth, max(120, area.width - 2 * panelInset)) + panelInset
        let x = side == .right ? screen.visibleFrame.maxX - w : screen.visibleFrame.minX
        var y = anchorY - h / 2
        y = min(max(y, area.minY), area.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h).integral
    }

    /// Whether a full-screen window covers `screen`. `windows` comes from the window server
    /// (`CGWindowListCopyWindowInfo`); bounds are in CoreGraphics coordinates (origin at the
    /// top-left of the primary display), which only exposes geometry, layer and owner — no titles,
    /// so no Screen Recording permission is involved.
    static func isFullScreen(_ screen: DockScreen, windows: [WindowSnapshot], primaryHeight: CGFloat, ownPID: pid_t) -> Bool {
        let cg = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                        width: screen.frame.width, height: screen.frame.height)
        return windows.contains { w in
            w.layer == 0 && w.ownerPID != ownPID && w.alpha > 0.01
                && abs(w.bounds.minX - cg.minX) <= adjacencyTolerance && abs(w.bounds.minY - cg.minY) <= adjacencyTolerance
                && abs(w.bounds.width - cg.width) <= adjacencyTolerance && abs(w.bounds.height - cg.height) <= adjacencyTolerance
        }
    }
}

/// The geometry the window server reports for one on-screen window.
struct WindowSnapshot: Hashable, Sendable {
    var bounds: CGRect
    var layer: Int
    var ownerPID: pid_t
    var alpha: Double

    /// On-screen windows of all apps (normal layer only matters for full-screen detection).
    static func onScreen() -> [WindowSnapshot] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[CFString: Any]] else { return [] }
        return list.compactMap { info in
            guard let boundsDict = info[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            return WindowSnapshot(bounds: bounds,
                                  layer: (info[kCGWindowLayer] as? NSNumber)?.intValue ?? 0,
                                  ownerPID: pid_t((info[kCGWindowOwnerPID] as? NSNumber)?.int32Value ?? 0),
                                  alpha: (info[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1)
        }
    }
}
