#if os(tvOS)
import XCTest
@testable import Silo

final class TVEpisodeRailDownGateTests: XCTestCase {
    private let start = ContinuousClock.now

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        start.advanced(by: .milliseconds(milliseconds))
    }

    func testSwipeTailDownAfterLateralMoveIsIgnored() {
        let decision = TVEpisodeRailDownGate.decide(
            now: at(600),
            lastLateralMove: at(0),
            lastDownPress: nil
        )
        XCTAssertEqual(decision, .ignored(sinceLateralMove: .milliseconds(600)))
    }

    func testDownAfterQuietPeriodReachesTheRailBelow() {
        let decision = TVEpisodeRailDownGate.decide(
            now: at(700),
            lastLateralMove: at(0),
            lastDownPress: nil
        )
        XCTAssertEqual(decision, .allowed(physicalPress: false))
    }

    func testPhysicalDownPressRightAfterLateralMoveStillMovesDown() {
        let decision = TVEpisodeRailDownGate.decide(
            now: at(200),
            lastLateralMove: at(100),
            lastDownPress: at(195)
        )
        XCTAssertEqual(decision, .allowed(physicalPress: true))
    }

    func testStalePhysicalPressDoesNotVouchForALaterSwipeTail() {
        let decision = TVEpisodeRailDownGate.decide(
            now: at(900),
            lastLateralMove: at(500),
            lastDownPress: at(0)
        )
        XCTAssertEqual(decision, .ignored(sinceLateralMove: .milliseconds(400)))
    }

    func testDownWithNoLateralMoveIsAllowed() {
        let decision = TVEpisodeRailDownGate.decide(
            now: at(0),
            lastLateralMove: nil,
            lastDownPress: nil
        )
        XCTAssertEqual(decision, .allowed(physicalPress: false))
    }
}
#endif
