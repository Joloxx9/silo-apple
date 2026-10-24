import Foundation

/// Request state for the seasons a series page lists as missing: whether a
/// season can be requested from here, which ones a request or a download
/// server already covers, and the request itself.
///
/// It loads only for a page that lists missing seasons, and offers requests
/// only while the requests feature is on for this profile and a download
/// server takes series requests.
@MainActor
@Observable
final class MissingSeasonRequests {
    /// A missing season can be requested from the series page.
    private(set) var canRequest = false
    private(set) var requestedSeasons: Set<Int> = []

    @ObservationIgnored private let api: SiloAPI
    @ObservationIgnored private var media: RequestMediaDetail?
    @ObservationIgnored private var generation: UInt = 0

    init(api: SiloAPI = .shared) {
        self.api = api
    }

    func load(tmdbId: String?, missing: MissingEpisodes) async {
        generation &+= 1
        let currentGeneration = generation
        guard missing != .none, let tmdbId = tmdbId.flatMap(Int.init), tmdbId > 0 else {
            reset()
            return
        }
        // A failed read keeps what the page showed; the next load asks again.
        // The page's task is cancelled when what it loads for changes, so a
        // cancelled load publishes nothing.
        guard let status = try? await api.requestsStatus(),
              !Task.isCancelled, currentGeneration == generation else { return }
        // A download server that cannot fetch single seasons would add the
        // whole series again, so the server says whether to offer them.
        guard status.isAvailable == true, status.seriesServerConnected == true,
              status.missingSeasonsRequestable == true else {
            reset()
            return
        }
        guard let media = try? await api.requestsDetail(mediaType: .series, tmdbId: tmdbId),
              !Task.isCancelled, currentGeneration == generation else { return }
        self.media = media
        requestedSeasons = Set((media.seasons ?? []).filter(\.requested).map(\.seasonNumber))
        canRequest = true
    }

    /// Requests one season. Reports whether the server took it.
    func request(season: Int) async -> Bool {
        guard canRequest, let media else { return false }
        let input = CreateRequestInput(
            mediaType: .series,
            tmdbId: media.tmdbId,
            tvdbId: media.tvdbId,
            imdbId: media.imdbId,
            title: media.title,
            year: media.year,
            overview: media.overview,
            posterPath: media.posterPath,
            backdropPath: media.backdropPath,
            seasons: [season]
        )
        do {
            let record = try await api.createRequest(input)
            RequestsEventBus.shared.publish(record)
            requestedSeasons.insert(season)
            return true
        } catch {
            // The server may have taken a request whose answer was lost, so
            // read the season back before offering Request again.
            if let fresh = try? await api.requestsDetail(mediaType: .series, tmdbId: media.tmdbId),
               (fresh.seasons ?? []).contains(where: { $0.seasonNumber == season && $0.requested }) {
                requestedSeasons.insert(season)
                return true
            }
            return false
        }
    }

    private func reset() {
        media = nil
        canRequest = false
        requestedSeasons = []
    }
}
