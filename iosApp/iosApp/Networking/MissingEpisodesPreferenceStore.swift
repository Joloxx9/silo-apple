import Foundation

/// The profile's `catalog.show_missing_episodes` choice, turned into the
/// scope the series page asks its season and episode lists for.
///
/// Read-only: the switch lives in the web client's Title Pages settings and
/// follows the profile to every device. With it on, aired episodes the
/// library lacks are listed; episodes still to air join them only while a
/// download server takes series requests, since only then can the page say
/// whether they are already on their way.
///
/// Like the advisory age, a change made elsewhere arrives at the next read:
/// the first series page after a profile switch or a return to the
/// foreground. A server older than the setting, or one that cannot be
/// reached, answers `.none`.
@MainActor
final class MissingEpisodesPreferenceStore {
    static let shared = MissingEpisodesPreferenceStore()

    private let api: SiloAPI
    private var answer: MissingEpisodes?
    private var pending: Task<ScopeRead, Never>?
    private var generation: UInt = 0

    init(api: SiloAPI = .shared) {
        self.api = api
    }

    /// The scope for this profile, read once and kept until ``markStale()``
    /// or ``clear()``.
    func scope() async -> MissingEpisodes {
        if let answer { return answer }
        if let pending { return await pending.value.scope }
        let currentGeneration = generation
        let task = Task { @MainActor [api] () -> ScopeRead in
            await Self.read(api: api)
        }
        pending = task
        let read = await task.value
        if generation == currentGeneration {
            pending = nil
            // A failed read answers for this page only; the next one asks again.
            if read.settled { answer = read.scope }
        }
        return read.scope
    }

    /// Lets the next ``scope()`` read again.
    func markStale() {
        generation &+= 1
        pending = nil
        answer = nil
    }

    func clear() {
        markStale()
    }

    /// A scope, and whether it is the server's answer rather than a fallback
    /// for a read that failed.
    private struct ScopeRead {
        let scope: MissingEpisodes
        let settled: Bool
    }

    private static func read(api: SiloAPI) async -> ScopeRead {
        guard case .available(let contract) = await api.getContractCapabilities(),
              contract.supports(.catalogShowMissingEpisodes) else {
            return ScopeRead(scope: .none, settled: true)
        }
        guard let values = try? await api.getEffectiveValues(keys: [.catalogShowMissingEpisodes]) else {
            return ScopeRead(scope: .none, settled: false)
        }
        guard values.value(for: .catalogShowMissingEpisodes)?.value.boolValue == true else {
            return ScopeRead(scope: .none, settled: true)
        }
        guard let status = try? await api.requestsStatus() else {
            return ScopeRead(scope: .aired, settled: false)
        }
        let scope: MissingEpisodes = status.isAvailable == true && status.seriesServerConnected == true ? .all : .aired
        return ScopeRead(scope: scope, settled: true)
    }
}
