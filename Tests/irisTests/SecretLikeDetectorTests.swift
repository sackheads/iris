import Testing
@testable import IrisKit

@Suite("A secret-shaped substring blocks Always-Allow from saving it (#1140)")
struct SecretLikeDetectorTests {
    // MARK: - Must fire

    @Test("an OAuth bearer header fires", arguments: [
        "curl -H 'Authorization: Bearer ya29.a0AfH6SMBx7example0123456789abcdefghij' https://api.example.com",
        "curl --header \"Authorization: Bearer sk-test-not-a-real-token-but-long-enough\" https://x",
    ])
    func bearerHeaderFires(_ command: String) {
        #expect(SecretLikeDetector.containsSecretLikeSubstring(command))
    }

    @Test("a JWT fires")
    func jwtFires() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9" + "." + "eyJzdWIiOiIxMjM0NTY3ODkwIn0" + "." + "dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        #expect(SecretLikeDetector.containsSecretLikeSubstring("curl -H 'Authorization: \(jwt)' https://x"))
    }

    // Built as whole strings assembled from parts ahead of the macro, not inline in its argument
    // list (that broke the type checker): a provider-shaped literal in the committed source also
    // trips GitHub's push protection (it did, for the Slack shape, round 1), even as a fixture,
    // never a real credential.
    private static let providerKeyFixtures: [String] = {
        let anthropic = "sk-ant-api03-" + "abcdefghijklmnopqrstuvwxyz0123456789"
        let github = "ghp_" + "abcdefghijklmnopqrstuvwxyz0123456789"
        let aws = "AKIA" + "ABCDEFGHIJKLMNOP"
        let slack = "xoxb-" + "NOTAREALSLACKTOKEN-fixtureonly"
        return [
            "curl -H 'x-api-key: \(anthropic)' https://x",
            "curl -H 'Authorization: token \(github)' https://x",
            "aws configure set aws_access_key_id \(aws)",
            "curl -H 'Authorization: Bearer \(slack)' https://x",
        ]
    }()

    @Test("provider key prefixes fire", arguments: providerKeyFixtures)
    func providerKeyPrefixesFire(_ command: String) {
        #expect(SecretLikeDetector.containsSecretLikeSubstring(command))
    }

    @Test("a named flag with a long opaque value fires", arguments: [
        "curl https://x?token=abcdefghijklmnopqrstuvwxyz0123456789",
        "mytool --apikey abcdefghijklmnopqrstuvwxyz0123456789",
        "mytool --access_token=abcdefghijklmnopqrstuvwxyz0123456789",
        "mytool --password=SuperSecretPassphrase1234567890",
    ])
    func namedFlagOpaqueValueFires(_ command: String) {
        #expect(SecretLikeDetector.containsSecretLikeSubstring(command))
    }

    @Test("an unlabeled mixed-case base64-shaped token of 40+ chars fires")
    func unlabeledMixedCaseTokenFires() {
        let token = "aZ3kP9mQ7vX2nR8wT1yU4bC6dE0fG5hJ8kL2mN7pQ9r"
        #expect(SecretLikeDetector.containsSecretLikeSubstring("curl -d 'auth=\(token)' https://x"))
    }

    // MARK: - Must NOT fire (the false-positive guard)

    @Test("a 40-hex git SHA does not fire")
    func gitSHADoesNotFire() {
        #expect(!SecretLikeDetector.containsSecretLikeSubstring("git checkout 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b"))
    }

    @Test("a longer lowercase-hex checksum (e.g. a SHA-256) does not fire")
    func sha256ChecksumDoesNotFire() {
        #expect(!SecretLikeDetector.containsSecretLikeSubstring(
            "shasum -a 256 -c <<< '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd file.tar'"))
    }

    @Test("a UUID does not fire, lowercase or Foundation's own uppercase spelling")
    func uuidDoesNotFire() {
        #expect(!SecretLikeDetector.containsSecretLikeSubstring("mytool --session-id 550e8400-e29b-41d4-a716-446655440000"))
        #expect(!SecretLikeDetector.containsSecretLikeSubstring("mytool --session-id 550E8400-E29B-41D4-A716-446655440000"))
    }

    @Test("a lowercase word hyphenated onto an uppercase UUID does not fire (#1140 round 1 regression)")
    func hyphenatedWordPlusUUIDDoesNotFire() {
        // UUID().uuidString is uppercase hex; "ordinary-" + "-" + UUID used to form one run that
        // had lowercase, uppercase and a digit, all in the pre-fix charset that allowed `-`.
        #expect(!SecretLikeDetector.containsSecretLikeSubstring("make ordinary-E4B5A1C2-9F3D-4A6B-8C7E-1D2F3A4B5C6D"))
    }

    @Test("a temp-directory path with an embedded UUID does not fire (#1140 round 1 regression)")
    func tempPathWithUUIDDoesNotFire() {
        #expect(!SecretLikeDetector.containsSecretLikeSubstring(
            "/private/var/folders/xx/yy/T/iris-256-E4B5A1C2-9F3D-4A6B-8C7E-1D2F3A4B5C6D/workspace/out.txt"))
    }

    @Test("a short, ordinary flag value does not fire")
    func shortFlagValueDoesNotFire() {
        #expect(!SecretLikeDetector.containsSecretLikeSubstring("mytool --name foo"))
    }

    @Test("a short password value under the length floor does not fire")
    func shortPasswordDoesNotFire() {
        #expect(!SecretLikeDetector.containsSecretLikeSubstring("mytool --password=x"))
    }

    @Test("an ordinary read-only command with no secret shape does not fire", arguments: [
        "git status", "swift test", "ls -la", "rg --files", "git log --oneline -20",
    ])
    func ordinaryCommandsDoNotFire(_ command: String) {
        #expect(!SecretLikeDetector.containsSecretLikeSubstring(command))
    }
}
