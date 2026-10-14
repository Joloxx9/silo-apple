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
        let position = seconds / interval
        let index = position >= Double(count - 1) ? count - 1 : Int(position)
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

    /// Whether another manifest lays out the same thumbnails, so its sheet
    /// URLs can replace these ones.
    func hasSameLayout(as other: ServerTrickplay) -> Bool {
        fileId == other.fileId && interval == other.interval
            && thumbnailWidth == other.thumbnailWidth && thumbnailHeight == other.thumbnailHeight
            && columns == other.columns && rows == other.rows && count == other.count
            && sheetURLs.count == other.sheetURLs.count
    }
}

/// Fetches one manifest's sheets and cuts thumbnails from them. Sheets are
/// kept as JPEG data, a few hundred kilobytes each, and only the most recent
/// one is kept decoded, so a long file does not hold every sheet in memory
/// as a bitmap.
actor ServerTrickplaySheets {
    /// How long a scrub waits for a sheet that is still downloading before
    /// it gives up on this target; the download carries on for later ones.
    private static let sheetWait: Duration = .seconds(1)
    /// Sheet URLs are renewed this long before the manifest says they expire.
    private static let renewalMargin: TimeInterval = 30

    private var trickplay: ServerTrickplay
    private let renew: @Sendable () async -> ServerTrickplay?
    private let session: URLSession
    private var data: [Int: Data] = [:]
    private var fetches: [Int: Task<Data?, Never>] = [:]
    private var renewal: Task<ServerTrickplay?, Never>?
    private var decoded: (sheet: Int, image: CGImage)?
    private var closed = false

    /// `renew` fetches the manifest again, for fresh sheet URLs once these
    /// expire.
    init(_ trickplay: ServerTrickplay, renew: @escaping @Sendable () async -> ServerTrickplay?) {
        self.trickplay = trickplay
        self.renew = renew
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// Cancels every download, so closing the player does not wait on them.
    func shutdown() {
        closed = true
        for fetch in fetches.values { fetch.cancel() }
        fetches = [:]
        renewal?.cancel()
        session.invalidateAndCancel()
    }

    /// Fetches every sheet in order, so a scrub anywhere in the file finds
    /// its thumbnail without a round trip. A whole film is a handful of
    /// sheets; one that fails is fetched again when a scrub needs it.
    func prefetch() async {
        for sheet in trickplay.sheetURLs.indices {
            if Task.isCancelled || closed { return }
            _ = await fetch(sheet).value
        }
    }

    /// The thumbnail for a source time, or nil when its sheet is not
    /// available within a short wait.
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
        guard !closed, trickplay.sheetURLs.indices.contains(sheet) else { return nil }
        if let bytes = data[sheet] { return bytes }
        return await Self.value(of: fetch(sheet), within: Self.sheetWait)
    }

    /// Waits for a sheet that is still downloading, however long it takes,
    /// and reports whether it is now held. A scrub that gave up on it uses
    /// this to ask again once it arrives. Without a download in flight there
    /// is nothing to wait for, so the answer is false.
    func awaitSheet(atSourceTime seconds: Double) async -> Bool {
        guard let tile = trickplay.tile(atSourceTime: seconds),
              data[tile.sheet] == nil, let fetch = fetches[tile.sheet] else { return false }
        _ = await fetch.value
        return !closed && data[tile.sheet] != nil
    }

    /// A download's result, or nil once `limit` passes. Returning at the
    /// deadline does not wait for or cancel the download: it is an
    /// unstructured task and keeps the sheet for the next scrub.
    private static func value(of fetch: Task<Data?, Never>, within limit: Duration) async -> Data? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { once.resume(with: await fetch.value) }
            Task {
                try? await Task.sleep(for: limit)
                once.resume(with: nil)
            }
        }
    }

    private func fetch(_ sheet: Int) -> Task<Data?, Never> {
        if let fetch = fetches[sheet] { return fetch }
        let fetch = Task<Data?, Never> {
            let bytes = await download(sheet)
            fetches[sheet] = nil
            if let bytes, !closed { data[sheet] = bytes }
            return bytes
        }
        fetches[sheet] = fetch
        return fetch
    }

    /// Downloads a sheet, renewing the manifest first when its URLs are
    /// about to expire, and once more when the server refuses them.
    private func download(_ sheet: Int) async -> Data? {
        if trickplay.expiresAt.timeIntervalSinceNow < Self.renewalMargin {
            await renewManifest()
        }
        var result = await get(sheet)
        if result.status == 401 || result.status == 403 {
            await renewManifest()
            result = await get(sheet)
        }
        return result.bytes
    }

    private func get(_ sheet: Int) async -> (bytes: Data?, status: Int) {
        guard !closed, !Task.isCancelled, trickplay.sheetURLs.indices.contains(sheet),
              let (bytes, response) = try? await session.data(from: trickplay.sheetURLs[sheet]) else {
            return (nil, 0)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status == 200 ? bytes : nil, status)
    }

    /// Replaces the sheet URLs with a fresh manifest's. Sheets already
    /// downloaded are kept; concurrent callers share one request.
    private func renewManifest() async {
        guard !closed else { return }
        if let renewal {
            // The download that started this renewal installs its result;
            // waiters only retry with whatever it installed.
            _ = await renewal.value
            return
        }
        let task = Task { [renew] in await renew() }
        renewal = task
        let renewed = await task.value
        renewal = nil
        guard !closed, let renewed, renewed.hasSameLayout(as: trickplay) else { return }
        trickplay = renewed
    }
}

/// Resumes a continuation with the first result offered and ignores the rest.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?

    init(_ continuation: CheckedContinuation<Data?, Never>) {
        self.continuation = continuation
    }

    func resume(with value: Data?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
