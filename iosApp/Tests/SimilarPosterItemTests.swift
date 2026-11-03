import Foundation
import XCTest
@testable import Silo

/// The phone's More Like This rail draws the watched check every other
/// poster row draws, from the card's own user state.
final class SimilarPosterItemTests: XCTestCase {
    private func card(played: Bool?) throws -> BrowseItem {
        let userState = played.map { #","user_state":{"played":\#($0),"is_favorite":false,"in_watchlist":false}"# } ?? ""
        let json = #"{"content_id":"movie:sheep","type":"movie","title":"Sheep Detectives","year":2026\#(userState)}"#
        return try JSONDecoder().decode(BrowseItem.self, from: Data(json.utf8))
    }

    func testWatchedCardShowsTheCheckAndSaysSo() throws {
        let item = SimilarPosterItem(card: try card(played: true))

        XCTAssertTrue(item.isPlayed)
        XCTAssertEqual(item.accessibilityDescription, "Sheep Detectives, 2026, Watched")
    }

    func testUnwatchedCardOrCardWithoutStateHasNoCheck() throws {
        XCTAssertFalse(SimilarPosterItem(card: try card(played: false)).isPlayed)
        XCTAssertFalse(SimilarPosterItem(card: try card(played: nil)).isPlayed)
    }
}
