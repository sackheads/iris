import Foundation

/// #611 option c: which folders the sandbox may mount read-write only with the person's opt-in.
///
/// A sandboxed command's workspace is mounted into the VM read-write, and commands there can run
/// with no prompt. A workspace that is the home folder or above it, or that holds a place a Mac
/// program runs or reads as configuration, would let the VM leave code behind for the host's
/// next command of any kind (`~/.zshenv`, a LaunchAgent, a `~/bin` tool). Such a workspace is
/// refused unless the person allowed it for that conversation, by path.
enum HomeMount {
    /// Places under home that a Mac program runs from or reads as configuration, beyond the
    /// credential stores (`JobGrant.credentialStores`). The shell's dotfiles live in home itself,
    /// which is covered by "home or above".
    static let startupLocations = ["~/Library/LaunchAgents", "~/.config", "~/bin", "~/.local/bin"]

    /// Whether `canonical` is one of `locations` (spelled from `~`), inside one, or holds one.
    static func touches(_ canonical: String, _ locations: [String], home: String) -> Bool {
        let lowered = canonical.lowercased()
        return locations.contains { entry in
            let place = IrisPaths.canonicalPath(home + entry.dropFirst()).lowercased()
            return lowered == place || lowered.hasPrefix(place + "/") || place.hasPrefix(lowered + "/")
        }
    }

    /// Whether `path` is the home folder, `/`, or a folder holding home. Shared with
    /// `JobGrant.resolve`, so a grant never depends on where Iris's own folder happens to be (#649).
    static func isHomeOrAbove(_ path: String, home: String) -> Bool {
        let p = IrisPaths.canonicalPath(IrisEngine.expandTilde(path)).lowercased()
        let h = IrisPaths.canonicalPath(home).lowercased()
        return p == "/" || p == h || h.hasPrefix(p + "/")
    }

    /// Why a sandbox may not mount `path` read-write without the opt-in, or nil when it may.
    /// `release`: in a dev build, the installed app's settings are guarded too, as `JobGrant`
    /// guards its home.
    static func reason(for path: String, home: String = NSHomeDirectory(), paths: IrisPaths = .default,
                       release: IrisPaths? = BuildIdentity.current == .dev ? .release : nil,
                       loginPath: [String] = BinaryResolver.defaultSearchDirs()) -> String? {
        let p = IrisPaths.canonicalPath(IrisEngine.expandTilde(path)).lowercased()
        if isHomeOrAbove(path, home: home) {
            return "it is your home folder or a folder above it, so the sandbox could rewrite your shell's startup files"
        }
        if touches(p, startupLocations, home: home) {
            return "it is or holds a folder your Mac runs programs or settings from (LaunchAgents, ~/.config, ~/bin)"
        }
        if JobGrant.isCredentialStore(p, home: home) {
            return "it is or holds a credential store (~/.ssh, ~/.aws, the Keychains folder and the like)"
        }
        // #616 review: a workspace at, inside or holding a login-PATH folder (`/opt/homebrew/bin` is
        // the person's own on Apple silicon) lets the VM leave a program their Terminal then runs.
        if let entry = JobGrant.loginPathEntry(touching: IrisPaths.canonicalPath(IrisEngine.expandTilde(path)), loginPath: loginPath) {
            return "it is, holds or sits inside \(entry), a folder on your login PATH, so the sandbox could leave a program your Terminal then runs"
        }
        let guarded = [paths] + (release.map { [$0] } ?? [])
        for dir in guarded.flatMap({ [$0.configDir.path, $0.pluginsDir.path] }) {
            let d = IrisPaths.canonicalPath(dir).lowercased()
            if p == d || p.hasPrefix(d + "/") || d.hasPrefix(p + "/") {
                return "it is or holds Iris's own settings, which decide what runs without asking"
            }
        }
        return nil
    }

    /// Whether `optIn` (a conversation's `homeWritableOptIn`) covers `path`: the same folder.
    static func isCovered(_ path: String, by optIn: String?) -> Bool {
        guard let optIn else { return false }
        return IrisPaths.canonicalPath(IrisEngine.expandTilde(path)) == IrisPaths.canonicalPath(optIn)
    }

    /// What the confirmation names before the person allows it: exactly what becomes writable.
    static func optInWarning(path: String) -> String {
        let why = reason(for: path) ?? "it holds files your Mac uses"
        return "Commands in this conversation's sandbox will be able to change anything in \(path), read-write, and \(why). Code left there can run on your Mac later, even in a command you approve yourself. While this is on, Vibecop only lets read-only commands run in the sandbox without asking. It applies to this conversation and this folder only, and you can stop it from the same menu."
    }

    /// The tool result for a refused sandboxed command. Nothing runs, and there is no fallback.
    static func refusal(path: String, reason: String) -> String {
        "Not run: the sandbox would mount \(path) read-write, and \(reason). The person can allow it for this conversation (right-click it in the sidebar: Let the Sandbox Write This Folder…), or the work can move to a project folder."
    }
}
