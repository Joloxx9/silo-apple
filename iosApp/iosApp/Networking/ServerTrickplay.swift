import CoreGraphics
import Foundation
import ImageIO

/// Seek-bar previews the server published for one file: sprite sheets of
/// thumbnails, one thumbnail per interval of source time. Unlike stills cut
/// from the player's cache, they cover the whole file before any of it has
/// been buffered.
struct ServerTrickplay: Equatable, Sendable {
    let fileId: Int
    /// Source time each thumbnail covers, in seconds.
    let interval: Double
    let thumbnailWidth: Int
    let thumbnailHeight: Int
    let columns: Int
    let rows: Int
    let count: Int
    /// One URL per sheet, in order. Each carries its own authorization.
    let sheetURLs: [URL]
    let expiresAt: Date

    struct Tile: Equatable {
        let sheet: Int
        /// The thumbnail's rectangle within its sheet, at full size.
        let rect: CGRect
    }

    enum InvalidManifest: Error {
        case geometry
        case sheets
    }

    /// The thumbnail shown for a source time, clamped to the last one.
    func tile(atSourceTime seconds: Double) -> Tile? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let index = min(Int(seconds / interval), count - 1)
        let perSheet = columns * rows
        let cell = index % perSheet
        return Tile(
            sheet: index / perSheet,
            rect: CGRect(
                x: (cell % columns) * thumbnailWidth,
                y: (cell / columns) * thumbnailHeight,
                width: thumbnailWidth,
                height: thumbnailHeight
            )
        )
    }
}

/// Fetches one manifest's sheets and cuts thumbnails from them. Sheets are
/// kept as JPEG data, a few hundred kilobytes each, and only the most recent
/// one is kept decoded, so a long file does not hold every sheet in memory
/// as a bitmap.
actor ServerTrickplaySheets {
    let trickplay: ServerTrickplay
    private let session: URLSession
    private var data: [Int: Data] = [:]
    private var fetches: [Int: Task<Data?, Never>] = [:]
    private var decoded: (sheet: Int, image: CGImage)?

    init(_ trickplay: ServerTrickplay) {
        self.trickplay = trickplay
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Fetches every sheet in order, so a scrub anywhere in the file finds
    /// its thumbnail without a round trip. A whole film is a handful of
    /// sheets; one that fails is fetched again when a scrub needs it.
    func prefetch() async {
        for sheet in trickplay.sheetURLs.indices {
            if Task.isCancelled { return }
            _ = await sheetData(sheet)
        }
    }

    func thumbnail(atSourceTime seconds: Double) async -> CGImage? {
        guard let tile = trickplay.tile(atSourceTime: seconds),
              let image = await sheetImage(tile.sheet) else { return nil }
        // A sheet is laid out at the manifest's size; scale the cut if the
        // image is not.
        let scale = CGFloat(image.width) / CGFloat(trickplay.columns * trickplay.thumbnailWidth)
        let rect = CGRect(
            x: tile.rect.minX * scale, y: tile.rect.minY * scale,
            width: tile.rect.width * scale, height: tile.rect.height * scale
        ).integral
        return image.cropping(to: rect)
    }

    private func sheetImage(_ sheet: Int) async -> CGImage? {
        if let decoded, decoded.sheet == sheet { return decoded.image }
        guard let bytes = await sheetData(sheet),
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(
                  source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else { return nil }
        decoded = (sheet, image)
        return image
    }

    private func sheetData(_ sheet: Int) async -> Data? {
        guard trickplay.sheetURLs.indices.contains(sheet) else { return nil }
        if let bytes = data[sheet] { return bytes }
        if let fetch = fetches[sheet] { return await fetch.value }
        let url = trickplay.sheetURLs[sheet]
        let session = session
        let fetch = Task<Data?, Never> {
            guard let (bytes, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return bytes
        }
        fetches[sheet] = fetch
        let bytes = await fetch.value
        fetches[sheet] = nil
        if let bytes { data[sheet] = bytes }
        return bytes
    }
}
