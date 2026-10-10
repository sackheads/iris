import Foundation

/// `iris://run-job/<token>` (D6 decisions 10 and 12): the link that fires one opted-in job. It
/// carries no input, so no URL content reaches a model and the taint is untouched. Adding any
/// parameter reopens decision 12.
enum RunJobURL {
    static let host = "run-job"

    /// D6 decision 13: URL fires per job per rolling hour, below the breaker's 6.
    static let maxFiresPerHour = 3

    static func url(token: String, identity: BuildIdentity) -> String {
        "\(identity.urlScheme)://\(host)/\(token)"
    }
}
