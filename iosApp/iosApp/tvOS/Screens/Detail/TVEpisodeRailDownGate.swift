#if os(tvOS)
import Foundation

/// Decides whether a Down command on the composite episode carousel is a
/// deliberate move to the rail below it.
///
/// A touch-surface swipe along the carousel can end with a vertical component,
/// which tvOS delivers as a trailing `.down` move command. Down hands focus to
/// Cast, so without this gate a sideways swipe could drop focus off the
/// carousel. A Down within `lateralQuietPeriod` of a Left/Right move is
/// ignored unless a physical Down press (a clickpad or D-pad click, which
/// `TVEpisodeHoldRepeat` observes) accompanies it.
@MainActor
final class TVEpisodeRailDownGate {
    enum Decision: Equatable {
        case allowed(physicalPress: Bool)
        case ignored(sinceLateralMove: Duration)
    }

    static let lateralQuietPeriod: Duration = .milliseconds(700)
    /// How recently a physical Down press must have begun to vouch for the
    /// move command it produced.
    static let pressWindow: Duration = .milliseconds(250)

    private var lastLateralMove: ContinuousClock.Instant?
    private var lastDownPress: ContinuousClock.Instant?

    func recordLateralMove(at now: ContinuousClock.Instant = .now) {
        lastLateralMove = now
    }

    func recordDownPress(at now: ContinuousClock.Instant = .now) {
        lastDownPress = now
    }

    func decideDown(at now: ContinuousClock.Instant = .now) -> Decision {
        Self.decide(now: now, lastLateralMove: lastLateralMove, lastDownPress: lastDownPress)
    }

    nonisolated static func decide(
        now: ContinuousClock.Instant,
        lastLateralMove: ContinuousClock.Instant?,
        lastDownPress: ContinuousClock.Instant?
    ) -> Decision {
        let physicalPress = lastDownPress.map { now - $0 <= pressWindow } ?? false
        guard !physicalPress,
              let lastLateralMove,
              now - lastLateralMove < lateralQuietPeriod else {
            return .allowed(physicalPress: physicalPress)
        }
        return .ignored(sinceLateralMove: now - lastLateralMove)
    }
}
#endif
