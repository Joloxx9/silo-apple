#if os(tvOS)
import UIKit

/// Records how focus leaves the composite episode carousel, so a field report
/// of a side swipe escaping it shows what the focus engine actually did.
///
/// One essential line per exit, written to the diagnostics ring that "Send
/// Diagnostics Now" freezes. It carries the engine's heading, the type and
/// screen frame of the item that took focus, the carousel's last move command
/// and how long before the exit it ran, and how often the edge fences refused
/// focus while the carousel held it. Entries into the carousel and every Down
/// decision (`TVEpisodeRailDownGate`) are logged too. Only type names,
/// geometry, and positions are recorded; breadcrumbs must stay free of library
/// content.
@MainActor
final class TVEpisodeRailFocusTrace {
    private weak var railItem: UIFocusItem?
    private var isArmed = false
    private var lastMove: (name: String, at: ContinuousClock.Instant)?
    private var fenceRefusals = 0
    private var observer: NSObjectProtocol?
    /// The carousel's frame in global (screen) coordinates.
    var railFrame: CGRect = .null

    /// Mirrors the carousel's `railHasFocus`. SwiftUI can report a change
    /// before or after the engine's own update notification — a programmatic
    /// `railHasFocus = true` reports it before the engine has moved focus at
    /// all — so the rail's focus item is whichever candidate lies inside the
    /// carousel's frame. A loss leaves the trace armed: the exit is logged
    /// from the engine's notification, which disarms it.
    func railFocusChanged(_ hasFocus: Bool) {
        guard hasFocus else { return }
        isArmed = true
        railItem = nil
        lastMove = nil
        fenceRefusals = 0
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: UIFocusSystem.didUpdateNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                    as? UIFocusUpdateContext else { return }
                MainActor.assumeIsolated { self?.focusDidUpdate(context) }
            }
        }
        adoptIfRailItem(TVFocusSystemProbe.focusedItem())
    }

    /// Called when the carousel leaves the screen.
    func stop() {
        isArmed = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func recordMove(_ direction: Int) {
        lastMove = (direction < 0 ? "left" : "right", .now)
    }

    func recordUp() {
        lastMove = ("up", .now)
    }

    func recordDown(_ decision: TVEpisodeRailDownGate.Decision) {
        let message: String
        let action: String
        switch decision {
        case .allowed(let physicalPress):
            lastMove = ("down", .now)
            message = "down command handed to the rail below source=\(physicalPress ? "press" : "touch")"
            action = "down.forwarded"
        case .ignored(let sinceLateralMove):
            message = "down command ignored \(Self.milliseconds(sinceLateralMove))ms after a lateral move"
            action = "down.ignored"
        }
        DiagTrace.log(
            .essential,
            category: .focus,
            tag: "EpisodeRail",
            message: message,
            attrs: [
                "target": .string("episodeRail"),
                "action": .string(action),
            ]
        )
    }

    func recordFenceRefusal() {
        fenceRefusals += 1
    }

    private func focusDidUpdate(_ context: UIFocusUpdateContext) {
        if isInsideRail(context.nextFocusedItem), !isInsideRail(context.previouslyFocusedItem) {
            logEntry(context)
        }
        guard isArmed else { return }
        guard let railItem else {
            adoptIfRailItem(context.nextFocusedItem)
            return
        }
        guard context.previouslyFocusedItem === railItem,
              context.nextFocusedItem !== railItem else { return }
        isArmed = false

        let heading = Self.name(for: context.focusHeading)
        let next = context.nextFocusedItem
        let nextType = next.map { String(describing: type(of: $0)) } ?? "none"
        let expected = context.focusHeading == .up || context.focusHeading == .down
        let message = [
            "focus left episode carousel",
            "heading=\(heading)",
            "next=\(nextType)",
            Self.geometry(of: next),
            lastMoveSummary,
            "fenceRefusals=\(fenceRefusals)",
        ].joined(separator: " ")

        DiagTrace.log(
            .essential,
            level: expected ? .info : .warning,
            category: .focus,
            tag: "EpisodeRail",
            message: message,
            attrs: [
                "target": .string(nextType),
                "action": .string("exit.\(heading)"),
            ]
        )
    }

    private func adoptIfRailItem(_ item: UIFocusItem?) {
        guard isInsideRail(item) else { return }
        railItem = item
    }

    private func isInsideRail(_ item: UIFocusItem?) -> Bool {
        guard let item, !railFrame.isNull,
              let frame = Self.screenFrame(of: item) else { return false }
        return railFrame.minY...railFrame.maxY ~= frame.midY
    }

    private func logEntry(_ context: UIFocusUpdateContext) {
        let heading = Self.name(for: context.focusHeading)
        let previous = context.previouslyFocusedItem
        let previousType = previous.map { String(describing: type(of: $0)) } ?? "none"
        DiagTrace.log(
            .essential,
            category: .focus,
            tag: "EpisodeRail",
            message: "focus entered episode carousel heading=\(heading) previous=\(previousType) \(Self.geometry(of: previous))",
            attrs: [
                "target": .string("episodeRail"),
                "action": .string("enter.\(heading)"),
            ]
        )
    }

    private var lastMoveSummary: String {
        guard let lastMove else { return "lastMove=none" }
        return "lastMove=\(lastMove.name) \(Self.milliseconds(ContinuousClock.now - lastMove.at))ms"
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000
    }

    /// SwiftUI's focus items (`UIKitFocusableViewResponderItem`) have no
    /// `focusItemContainer`; their `frame` is in the coordinate space of the
    /// nearest hosting view among their parent focus environments. Window
    /// coordinates are the screen's on tvOS.
    private static func screenFrame(of item: UIFocusItem) -> CGRect? {
        if let container = item.focusItemContainer {
            guard let screen = TVFocusSystemProbe.keyWindowScreen else { return nil }
            return container.coordinateSpace.convert(item.frame, to: screen.coordinateSpace)
        }
        var environment = item.parentFocusEnvironment
        while let current = environment, !(current is UIView) {
            environment = current.parentFocusEnvironment
        }
        guard let view = environment as? UIView, view.window != nil else { return nil }
        return view.convert(item.frame, to: nil)
    }

    private static func geometry(of item: UIFocusItem?) -> String {
        guard let item, let frame = screenFrame(of: item),
              let screen = TVFocusSystemProbe.keyWindowScreen else { return "frame=unknown" }
        let visibility = screen.bounds.contains(frame)
            ? "onScreen"
            : screen.bounds.intersects(frame) ? "partlyOffScreen" : "offScreen"
        return "frame=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height)) \(visibility)"
    }

    private static func name(for heading: UIFocusHeading) -> String {
        switch heading {
        case []: "none"
        case .up: "up"
        case .down: "down"
        case .left: "left"
        case .right: "right"
        case .next: "next"
        case .previous: "previous"
        default: "raw\(heading.rawValue)"
        }
    }
}
#endif
