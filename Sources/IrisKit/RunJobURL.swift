import Foundation

/// `iris://run-job/<token>` (D6 decisions 10 and 12): the link that fires one opted-in job. It
/// carries no input, so no URL content reaches a model and the taint is untouched. Adding any
/// parameter reopens decision 12.
enum RunJobURL {
    static let host = "run-job"

    /// D6 decision 13: URL fires per job per rolling hour, below the breaker's 6.
    static let maxFiresPerHour = 3

    /// Plan note 9: a URL fire costs Iris one line, posted now and updated when admission answers.
    static func firingLine(_ name: String) -> String { "Firing \(name) from a URL …" }
    static func firedLine(_ name: String) -> String { "Fired \(name) from a URL; the result arrives as a card." }
    static func notStartedLine(_ name: String, _ why: String) -> String {
        "Refused a URL fire of \(name): it was not started, because \(why)."
    }

    static func url(token: String, identity: BuildIdentity) -> String {
        "\(identity.urlScheme)://\(host)/\(token)"
    }
}
