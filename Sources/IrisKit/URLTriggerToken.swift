import CryptoKit
import Foundation
import Security

/// The capability a URL trigger carries (D6 decision 10): 128 random bits, base64url-encoded.
/// Not the job id, which sits in the ledger and in transcripts, where an approved host
/// `run_command` could `open` it. Only the SHA-256 digest is stored, and the link itself is shown
/// once in a transient sheet and never written to a message (plan note 17): the token cannot be
/// shown twice, and a leaked database holds no live URL.
enum URLTriggerToken {
    static let byteCount = 16
    static let encodedLength = 22

    /// A fresh token, or nil when the system's random source failed. Then nothing is stored and
    /// the owner is told.
    static func generate(fill: (inout [UInt8]) -> Bool = URLTriggerToken.secureFill) -> String? {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard fill(&bytes) else { return nil }
        return base64url(bytes)
    }

    static func secureFill(_ bytes: inout [UInt8]) -> Bool {
        SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
    }

    static func base64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Exactly what `generate` makes. A job id, a name, or anything percent-encoded is not.
    static func isWellFormed(_ token: String) -> Bool {
        token.count == encodedLength && token.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0)
                || $0 == "-" || $0 == "_"
        }
    }
}
