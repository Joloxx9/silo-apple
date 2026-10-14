import Foundation
import XCTest
@testable import Silo

final class ServerTrickplayTests: XCTestCase {
    private func manifest(count: Int = 250, columns: Int64 = 10, sheets: [(Int, String)]? = nil) throws -> ServerTrickplay {
        let sheetList = (sheets ?? [(1, "/api/v2/images/s1?sig=b"), (0, "/api/v2/images/s0?sig=a"), (2, "/api/v2/images/s2?sig=c")])
            .map { #"{"index":\#($0.0),"url":"\#($0.1)"}"# }
            .joined(separator: ",")
        let json = #"""
        {"file_id":"42","interval_ms":10000,"thumbnail_width":320,"thumbnail_height":180,
         "tile_columns":\#(columns),"tile_rows":10,"thumbnail_count":\#(count),
         "sheets":[\#(sheetList)],"expires_at":"2026-01-02T03:04:05.000Z"}
        """#
        let decoder = HTTPClient.makeJSONDecoder(artworkServerURL: URL(string: "https://silo.example:8090/api/v2/watch/movie:x/trickplay"))
        return try ServerTrickplay(v2: decoder.decode(APIv2CatalogRead.WatchTrickplay.self, from: Data(json.utf8)))
    }

    func testDecodesSheetsInIndexOrderAgainstTheServerOrigin() throws {
        let trickplay = try manifest()
        XCTAssertEqual(trickplay.fileId, 42)
        XCTAssertEqual(trickplay.interval, 10)
        XCTAssertEqual(trickplay.sheetURLs.map(\.absoluteString), [
            "https://silo.example:8090/api/v2/images/s0?sig=a",
            "https://silo.example:8090/api/v2/images/s1?sig=b",
            "https://silo.example:8090/api/v2/images/s2?sig=c",
        ])
    }

    func testTileCoversTheWholeFileAndClampsToTheLastThumbnail() throws {
        let trickplay = try manifest()
        XCTAssertEqual(trickplay.tile(atSourceTime: 0), .init(sheet: 0, rect: CGRect(x: 0, y: 0, width: 320, height: 180)))
        // Thumbnail 123 = sheet 1, cell 23: column 3, row 2.
        XCTAssertEqual(trickplay.tile(atSourceTime: 1235), .init(sheet: 1, rect: CGRect(x: 960, y: 360, width: 320, height: 180)))
        // Past the end shows thumbnail 249 = sheet 2, cell 49.
        XCTAssertEqual(trickplay.tile(atSourceTime: 99_999), .init(sheet: 2, rect: CGRect(x: 2880, y: 720, width: 320, height: 180)))
        XCTAssertEqual(trickplay.tile(atSourceTime: 1e300)?.sheet, 2)
        XCTAssertNil(trickplay.tile(atSourceTime: -1))
        XCTAssertNil(trickplay.tile(atSourceTime: .nan))
    }

    func testRejectsAManifestWhoseSheetsDoNotHoldEveryThumbnail() {
        XCTAssertThrowsError(try manifest(count: 350))
        XCTAssertThrowsError(try manifest(sheets: [(0, "/a"), (1, "/b"), (2, "ftp://x/c")]))
    }

    func testRejectsGeometryThatOverflows() {
        XCTAssertThrowsError(try manifest(count: 1, columns: .max, sheets: [(0, "/a")]))
    }
}
