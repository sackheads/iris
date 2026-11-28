import Foundation

/// #1435 slice 3 (Brian's F5): on the host, `run_command`'s git holds no credential, and the commands that would reach a
/// forge or change what git runs always ask the person: no allowlist rule, no Vibecop, no YOLO. Everything remote goes
/// through `vcs` (`VCSMirror`), which holds the credential and enforces the policy.
///
/// This is the host tier's line until host agents are contained (#1435's spike, S5): a person-approved command still
/// runs as the person, so what this buys is that nothing approves these on its own, and that an approved `git push`
/// has no token to push with.
enum HostVCSCommands {
    /// git subcommands that talk to a remote, or run another machine's program.
    static let transportSubcommands: Set<String> = [
        "push", "fetch", "pull", "clone", "ls-remote", "remote", "submodule", "send-email", "request-pull",
        "archive", "fetch-pack", "send-pack", "upload-pack", "receive-pack", "http-fetch", "http-push", "svn", "p4",
    ]

    /// git's global options that change which config, programs or repository it uses.
    static let refusedGlobalOptions: Set<String> = ["-c", "--config-env", "--exec-path", "--git-dir", "--work-tree", "--namespace"]

    /// Words that run the next word as a program.
    static let wrappers: Set<String> = ["env", "command", "exec", "xargs", "nice", "nohup", "time", "sudo", "doas", "caffeinate",
                                        "timeout", "gtimeout", "stdbuf", "arch", "builtin", "noglob", "chroot"]

    static let reason = "This command reaches a code host or changes what git runs, so only you can approve it, every time. Agents push and open PRs through vcs."

    /// Whether `command` needs the person on the host: `gh` in any form; git spelled as a path or run through another
    /// program; git with a transport subcommand; git with `-c`, `--config-env`, `--exec-path` or a repository option.
    /// A command the tokenizer can't model is judged by its text, on the side of asking.
    static func needsPerson(_ command: String) -> Bool {
        guard let segments = CommandPattern.segments(command) else { return textNeedsPerson(command) }
        // Any word naming a git variable (`GIT_CONFIG_COUNT=0 git …`, `export GIT_CONFIG_COUNT=0; git …`,
        // `unset GIT_CONFIG_COUNT`) can undo the credential strip, in whichever part of the command it sits.
        if segments.contains(where: { $0.words.contains(where: touchesGitEnvironment) }) { return true }
        return segments.contains { needsPerson(words: $0.words) }
    }

    static func touchesGitEnvironment(_ word: String) -> Bool {
        let name = word.drop { $0 == "$" || $0 == "{" }
        return name.hasPrefix("GIT_") || name.hasPrefix("SSH_ASKPASS")
    }

    /// The keychain CLI's subcommands that print or export a secret (planner, #1435): git's helper reads the person's
    /// Keychain with no prompt, and `security` can too.
    static let securitySecretSubcommands: Set<String> = [
        "find-internet-password", "find-generic-password", "find-key", "find-certificate", "dump-keychain", "export",
        "unlock-keychain", "set-keychain-settings", "add-internet-password", "add-generic-password",
    ]

    static func needsPerson(words: [String]) -> Bool {
        var i = 0
        // Leading `VAR=value` assignments and wrappers: git or gh behind them is git or gh run another way. An assignment
        // can undo the credential strip (`GIT_CONFIG_COUNT=0 git …`, dev-3's #1453 review), so it counts as a wrapper.
        var wrapped = false
        while i < words.count {
            let word = words[i]
            if word.contains("="), !word.hasPrefix("-"), word.first.map({ $0.isLetter || $0 == "_" }) == true { wrapped = true; i += 1; continue }
            if wrappers.contains(basename(word)) { wrapped = true; i += 1; while i < words.count, words[i].hasPrefix("-") { i += 1 }; continue }
            break
        }
        guard i < words.count else { return false }
        let program = words[i]
        let name = basename(program)
        // `git-credential-osxkeychain` and the other `git-*` programs, run directly, read or move credentials too.
        if name == "gh" || name.hasPrefix("git-") { return true }
        if name == "security" {
            return words[(i + 1)...].first { !$0.hasPrefix("-") }.map(securitySecretSubcommands.contains) ?? false
        }
        guard name == "git" else { return false }
        if wrapped || program.contains("/") { return true }
        var j = i + 1
        while j < words.count, words[j].hasPrefix("-") {
            let option = String(words[j].prefix { $0 != "=" })
            if refusedGlobalOptions.contains(option) { return true }
            j += (option == "-C" && !words[j].contains("=")) ? 2 : 1
        }
        guard j < words.count else { return false }
        let subcommand = words[j]
        // `credential fill` asks the helpers for a credential; `credential-*` is a helper itself.
        if subcommand == "credential" || subcommand.hasPrefix("credential-") { return true }
        // `git config` that sets an alias, a credential setting or an include: each can bring the credential back later.
        if subcommand == "config", words[(j + 1)...].contains(where: { word in
            let key = word.lowercased()
            return key.hasPrefix("alias.") || key.hasPrefix("credential") || key.hasPrefix("include") || key.hasPrefix("core.sshcommand")
                || key.hasPrefix("core.askpass") || key.hasPrefix("http.") || key.hasPrefix("url.")
        }) { return true }
        return transportSubcommands.contains(subcommand)
    }

    private static func basename(_ word: String) -> String {
        String(word.split(separator: "/", omittingEmptySubsequences: true).last ?? Substring(word))
    }

    private static func textNeedsPerson(_ command: String) -> Bool {
        let patterns = [#"(^|[^A-Za-z0-9_.-])gh([^A-Za-z0-9_.-]|$)"#,
                        #"/git([^A-Za-z0-9_.-]|$)"#,
                        #"(^|[^A-Za-z0-9_.-])git\s+(-c|--config-env|--exec-path|--git-dir|--work-tree)"#,
                        #"(^|[^A-Za-z0-9_.-])git(-|\s+)credential"#,
                        #"GIT_[A-Z_]+"#,
                        #"(^|[^A-Za-z0-9_.-])security\s+(\S+\s+)*?(find-internet-password|find-generic-password|find-key|dump-keychain|export)"#,
                        #"(^|[^A-Za-z0-9_.-])git\s+(\S+\s+)*?(push|fetch|pull|clone|ls-remote|remote|submodule|send-email|archive)([^A-Za-z0-9_.-]|$)"#]
        return patterns.contains { command.range(of: $0, options: .regularExpression) != nil }
    }

    /// The environment a host command's git runs with: no credential helper from any config (an empty value at command
    /// scope, read last, clears the list), no prompt, no askpass, and no ssh, so neither Iris's token nor the person's
    /// own (a keychain helper, an ssh key) is reachable from it.
    static func withoutCredentials(_ base: [String: String]) -> [String: String] {
        var env = base
        let pairs = [("credential.helper", ""), ("core.askPass", ""), ("core.sshCommand", "/usr/bin/false")]
        let existing = Int(base["GIT_CONFIG_COUNT"] ?? "") ?? 0
        env["GIT_CONFIG_COUNT"] = String(existing + pairs.count)
        for (offset, pair) in pairs.enumerated() {
            env["GIT_CONFIG_KEY_\(existing + offset)"] = pair.0
            env["GIT_CONFIG_VALUE_\(existing + offset)"] = pair.1
        }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "/usr/bin/false"
        env["SSH_ASKPASS"] = "/usr/bin/false"
        env["GIT_SSH_COMMAND"] = "/usr/bin/false"
        env["GIT_SSH"] = "/usr/bin/false"
        return env
    }
}
