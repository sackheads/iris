import SwiftUI

/// Settings → Integrations → GitHub (#966): the account login, the token and the allowed repositories,
/// drawn over `GitHubSettingsModel`, which holds every rule. The token field is write-only: it is
/// cleared after a save and the pane shows only `KeyHint`'s suffix.
struct GitHubSettingsSection: View {
    @State private var model: GitHubSettingsModel
    @State private var tokenDraft = ""
    @State private var loginDraft = ""
    @State private var repoDraft = ""
    @State private var message: String?

    init(config: ConfigManager = .shared) {
        _model = State(initialValue: GitHubSettingsModel(
            config: config, toolsOfferedAtLaunch: config.githubToolsConfigured))
    }

    private var editable: Bool { model.editState == .editable }

    var body: some View {
        Section(header: Text(model.login.map { "GitHub (\($0))" } ?? "GitHub").font(.headline)) {
            if case .disabled(let reason) = model.editState {
                Text(reason).font(.caption).foregroundColor(.orange)
            }

            TextField("Account username", text: $loginDraft)
                .disabled(!editable)
                .onSubmit(saveLogin)
            Text("Account: " + (model.login ?? "not set")).font(.caption).foregroundColor(.secondary)
            HStack {
                Button("Save account", action: saveLogin)
                    .disabled(!editable || loginDraft.isEmpty)
                Button("Remove account") { report(model.clearLogin()) }
                    .disabled(!editable || model.login == nil)
                Button("Check token") { Task { await model.verifyIdentity() } }
                    .disabled(model.login == nil || model.tokenHint == "not set" || model.identity == .checking)
            }
            if model.storedLoginUnreadable {
                Text("The stored account username cannot be read, so the GitHub tools stay off. Saving one replaces it.")
                    .font(.caption).foregroundColor(.orange)
            }
            identityLine

            SecureField("Personal access token", text: $tokenDraft)
                .disabled(!editable)
                .onSubmit(saveToken)
            Text("Token: " + model.tokenHint).font(.caption).foregroundColor(.secondary)
            HStack {
                Button("Save token", action: saveToken)
                    .disabled(!editable || tokenDraft.isEmpty)
                Button("Remove token") { report(model.clearToken()) }
                    .disabled(!editable || model.tokenHint == "not set")
            }

            if model.storedListUnreadable {
                Text("The stored repository list cannot be read, so no repository is allowed. Adding one replaces it.")
                    .font(.caption).foregroundColor(.orange)
            }
            ForEach(model.repos, id: \.self) { repo in
                HStack {
                    Text(repo).font(.body.monospaced())
                    Spacer()
                    Button {
                        report(model.removeRepo(repo))
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!editable)
                    .accessibilityLabel("Remove \(repo)")
                }
            }
            HStack {
                TextField("owner/name", text: $repoDraft)
                    .disabled(!editable)
                    .onSubmit(addRepo)
                Button("Add", action: addRepo)
                    .disabled(!editable || repoDraft.isEmpty)
            }

            if let message {
                Text(message).font(.caption).foregroundColor(.red)
            }
            if model.needsRestart {
                Text("Restart Iris for the GitHub tools to change: they are read once at launch.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Text("The GitHub tools are offered only with an account, a token and at least one repository, and act only on the repositories listed here.")
                .font(.caption).foregroundColor(.secondary)
        }
        .onAppear { model.refresh() }
    }

    @ViewBuilder private var identityLine: some View {
        switch model.identity {
        case .unchecked: EmptyView()
        case .checking: Text("Checking the token with GitHub…").font(.caption).foregroundColor(.secondary)
        case .match: Text("The token belongs to this account.").font(.caption).foregroundColor(.green)
        case .mismatch(let actual):
            Text("This token belongs to \(actual), not the account above. Commits would be signed as one account while the token acts as the other.")
                .font(.caption).foregroundColor(.red)
        case .unverified(let why):
            Text("Could not confirm whose token this is: \(why).").font(.caption).foregroundColor(.orange)
        }
    }

    private func saveToken() {
        let failure = model.saveToken(tokenDraft)
        if failure == nil { tokenDraft = ""; Task { await model.verifyIdentity() } }
        report(failure)
    }

    private func saveLogin() {
        let failure = model.saveLogin(loginDraft)
        if failure == nil { loginDraft = ""; Task { await model.verifyIdentity() } }
        report(failure)
    }

    private func addRepo() {
        let failure = model.addRepo(repoDraft)
        if failure == nil { repoDraft = "" }
        report(failure)
    }

    private func report(_ failure: GitHubSettingsModel.Failure?) {
        message = failure?.message
    }
}
