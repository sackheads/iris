import Foundation
import Testing
@testable import IrisKit

@Suite("A secret-shaped substring blocks Always-Allow from saving it (#1140)")
struct SecretLikeDetectorTests {
    // MARK: - Must fire, one fixture per named pattern, isolated from every other pattern
    //
    // Each fixture is built so deleting the ONE pattern it targets reds its test, and only that
    // test: no "Authorization"/"token"/"password"/etc. keyword appears near a fixture unless that
    // keyword IS the thing under test, and no fixture's value is long/mixed enough to also trip
    // `hasGenericMixedCaseToken` (round 2, dev-2's finding: the old fixtures, wrapped in an
    // "Authorization: Bearer"/"token" context for realism, were each caught by TWO patterns, so
    // deleting either alone left the suite green).

    @Test("an OAuth bearer header fires, and a Bearer value that is a $VAR reference does not")
    func bearerHeaderFires() {
        #expect(SecretLikeDetector.containsSecretLikeSubstring("curl -H 'Authorization: Bearer shortvalue123' https://x"))
        #expect(!SecretLikeDetector.containsSecretLikeSubstring("curl -H 'Authorization: Bearer $GITHUB_TOKEN' https://x"),
                "a shell-variable reference is a placeholder, not a literal secret")
        #expect(!SecretLikeDetector.containsSecretLikeSubstring("curl -H 'Authorization: Bearer ${GITHUB_TOKEN}' https://x"))
    }

    @Test("a JWT fires, isolated from the Authorization-header and generic patterns")
    func jwtFires() {
        // No "Authorization" wording nearby, and the last segment kept under 40 chars so the
        // generic fallback can't also claim this fixture.
        let jwt = "eyJhbGciOiJIUzI1NiJ9" + "." + "eyJzdWIiOiIxMjM0NTY3ODkwIn0" + "." + "dGVzdHNpZ25hdHVyZTEyMw"
        #expect(SecretLikeDetector.containsSecretLikeSubstring("curl -d 'jwt=\(jwt)' https://x"))
    }

    @Test("an OpenAI/Anthropic sk- key fires, isolated from the named-flag pattern")
    func openAIOrAnthropicKeyFires() {
        let key = "sk-ant-api03-" + "abcdefghijklmnopqrstuvwxyz"
        #expect(SecretLikeDetector.containsSecretLikeSubstring("curl -H 'x-request-id: \(key)' https://x"))
    }

    @Test("a GitHub token fires, isolated from the named-flag pattern")
    func githubTokenFires() {
        let token = "ghp_" + "abcdefghijklmnopqrstuvwxyz"
        #expect(SecretLikeDetector.containsSecretLikeSubstring("curl -H 'x-request-id: \(token)' https://x"))
    }

    @Test("an AWS access key id fires, both the standing and temporary (ASIA) prefix")
    func awsAccessKeyIdFires() {
        #expect(SecretLikeDetector.containsSecretLikeSubstring("aws configure set aws_access_key_id " + "AKIA" + "ABCDEFGHIJKLMNOP"))
        #expect(SecretLikeDetector.containsSecretLikeSubstring("aws configure set aws_access_key_id " + "ASIA" + "ABCDEFGHIJKLMNOP"))
    }

    @Test("a Slack token fires, isolated from the Authorization-header pattern")
    func slackTokenFires() {
        let token = "xoxb-" + "NOTAREALSLACKTOKEN-fixtureonly"
        #expect(SecretLikeDetector.containsSecretLikeSubstring("curl -H 'x-request-id: \(token)' https://x"))
    }

    @Test("a Google API key fires")
    func googleAPIKeyFires() {
        let key = "AIza" + "abcdefghijklmnopqrstuvwxyz0123456789A"
        #expect(SecretLikeDetector.containsSecretLikeSubstring("curl -H 'x-request-id: \(key)' https://x"))
    }

    @Test("a Stripe live key fires")
    func stripeKeyFires() {
        let key = "sk_live_" + "abcdefghijklmnop"
        #expect(SecretLikeDetector.containsSecretLikeSubstring("curl -H 'x-request-id: \(key)' https://x"))
    }

    @Test("a Hugging Face token fires")
    func huggingFaceTokenFires() {
        let token = "hf_" + "abcdefghijklmnopqrstuvwxyz"
        #expect(SecretLikeDetector.containsSecretLikeSubstring("curl -H 'x-request-id: \(token)' https://x"))
    }

    @Test("a GitLab personal access token fires")
    func gitlabTokenFires() {
        let token = "glpat-" + "abcdefghijklmnopqrstuvwxyz"
        #expect(SecretLikeDetector.containsSecretLikeSubstring("curl -H 'x-request-id: \(token)' https://x"))
    }

    @Test("an npm auth token fires")
    func npmAuthTokenFires() {
        #expect(SecretLikeDetector.containsSecretLikeSubstring("echo '_authToken=" + "npm_abcdefghijklmnop" + "' >> .npmrc"))
    }

    @Test("an uppercase env-var assignment fires, and a $VAR-referencing one does not", arguments: [
        "NPM_TOKEN", "DB_PASSWORD", "GITHUB_TOKEN", "AWS_SECRET_ACCESS_KEY",
    ])
    func envVarAssignmentFires(_ name: String) {
        #expect(SecretLikeDetector.containsSecretLikeSubstring("export \(name)=shortvalue123"))
        #expect(!SecretLikeDetector.containsSecretLikeSubstring("export \(name)=$SOME_OTHER_VAR"))
    }

    @Test("a named CLI flag with an opaque value fires, hyphenated or not, space or = separated", arguments: [
        "mytool --apikey abcdefghijklmnop",
        "mytool --api-key abcdefghijklmnop",
        "mytool --access_token=abcdefghijklmnop",
        "mytool --password=SuperSecret1",
        "mysql --password hunter2x",
    ])
    func namedFlagOpaqueValueFires(_ command: String) {
        #expect(SecretLikeDetector.containsSecretLikeSubstring(command))
    }

    @Test("credentials embedded in a URL's userinfo fire")
    func urlUserinfoFires() {
        #expect(SecretLikeDetector.containsSecretLikeSubstring("git clone https://bob:hunter2hunter2@github.com/org/repo.git"))
    }

    @Test("curl's -u basic-auth flag fires, and a $VAR-referencing one does not")
    func curlBasicAuthFlagFires() {
        #expect(SecretLikeDetector.containsSecretLikeSubstring("curl -u bob:hunter2hunter2 https://x"))
        #expect(!SecretLikeDetector.containsSecretLikeSubstring("curl -u $USER:$PASS https://x"))
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

    @Test("a password value under the length floor does not fire")
    func shortPasswordDoesNotFire() {
        #expect(!SecretLikeDetector.containsSecretLikeSubstring("mytool --password=x"))
    }

    @Test("an ordinary read-only command with no secret shape does not fire", arguments: [
        "git status", "swift test", "ls -la", "rg --files", "git log --oneline -20",
    ])
    func ordinaryCommandsDoNotFire(_ command: String) {
        #expect(!SecretLikeDetector.containsSecretLikeSubstring(command))
    }

    // MARK: - Bounded time (#1140 round 2, the required fix)

    @Test("an adversarial run of 100,000 alternating characters completes in well under a second")
    func adversarialInputIsBoundedTime() {
        let adversarial = String(repeating: "a+", count: 50_000) // 100,000 chars
        let start = Date()
        _ = SecretLikeDetector.containsSecretLikeSubstring(adversarial)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0, "took \(elapsed)s — the generic fallback must be linear, not quadratic")
    }
}
