import Foundation

/// How much of what the library lacks a season or episode list includes.
///
/// Only the series page asks for more than `.none`: playback, downloads and
/// Top Shelf read the library alone, so they never offer an episode no file
/// backs.
enum MissingEpisodes: String, Hashable, Sendable {
    /// Only what a library holds.
    case none
    /// Also the aired regular episodes no library holds.
    case aired
    /// Also the regular episodes still to air, for a viewer whose download
    /// server can say whether they are already coming.
    case all

    /// The catalog list query that asks for this scope.
    var queryItems: [String: String] {
        switch self {
        case .none: return [:]
        case .aired: return ["include_missing": "true"]
        case .all: return ["include_missing": "true", "include_upcoming": "true"]
        }
    }

    /// Keeps a list that includes missing episodes apart from the library's
    /// own in ``ResponseCache``.
    var cacheKeySuffix: String {
        self == .none ? "" : ":missing-\(rawValue)"
    }
}
