import Testing
import Foundation
@testable import IrisKit

/// #1450 (planner's rulings): a host read Vibecop's APPROVE would run asks the person instead when its path has a
/// credential's shape, or a recursive read would walk into one; the person's own files elsewhere stay approvable.
@Suite("Vibecop's read approve and credential-shaped paths (#1450)")
struct SecretReadShapeTests {
    /// A home of its own, so the rows don't depend on the real one: `.ssh/id_ed25519`, `.netrc`, `.git-credentials`,
    /// `.config/gh/hosts.yml`, `Library/Keychains/x`, `d.md`, a vault note, `Documents/x`, and a workspace with its own
    /// `.git` and a link to the ssh key.
    struct Home {
        let root: URL
        var home: String { root.path }
        var workspace: String { root.appendingPathComponent("src/proj").path }
        func gate(_ command: String, tool: String = "run_command") -> ReadOnlyCommand.VibecopGate {
            let lookup = ReadOnlyCommand.HostLookup(path: "/bin:/usr/bin", cwd: workspace, home: home, writableRoots: [],
                                                    isExecutable: { _ in true })   // every program "found", so only the shape decides
            return ReadOnlyCommand.vibecopGate(toolName: tool, details: command, inSandbox: false, isOwner: true,
                                               cwd: workspace, workspace: workspace, lookup: lookup)
        }
    }

    func home() throws -> Home {
        let root = URL(fileURLWithPath: IrisPaths.canonicalPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("iris-1450-\(UUID().uuidString)")
        let fm = FileManager.default
        for dir in [".ssh", ".config/gh", "Library/Keychains", "vault/notes", "Documents", "src/proj/.git", "src/proj/.github", "notes"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for file in [".ssh/id_ed25519", ".netrc", ".git-credentials", ".config/gh/hosts.yml", "Library/Keychains/x", "d.md",
                     "vault/notes/a.md", "Documents/x", "src/proj/README.md", "src/proj/.git/HEAD", "src/proj/.github/ci.yml",
                     "src/proj/.env", "src/proj/server.pem", "notes/todo.md"] {
            try "x\n".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("src/proj/key").path,
                                  withDestinationPath: root.appendingPathComponent(".ssh/id_ed25519").path)
        return Home(root: root)
    }

    private func asks(_ gate: ReadOnlyCommand.VibecopGate) -> Bool { if case .ask = gate { return true } else { return false } }

    @Test("a hidden path under home, ~/Library, and a credential name anywhere ask, through run_command and read_file")
    func shapesAsk() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at: h.root) }
        let hidden = ["\(h.home)/.netrc", "\(h.home)/.ssh/id_ed25519", "\(h.home)/.config/gh/hosts.yml", "\(h.home)/.git-credentials"]
        for path in hidden + ["\(h.home)/Library/Keychains/x", "\(h.workspace)/.env", "\(h.workspace)/server.pem", "key"] {
            for program in ["cat", "grep x", "tail", "wc -l"] {
                #expect(asks(h.gate("\(program) \(path)")), "\(program) \(path)")
            }
            #expect(asks(h.gate(path.hasPrefix("/") ? path : "\(h.workspace)/\(path)", tool: "read_file")), "read_file \(path)")
        }
    }

    @Test("the person's own files elsewhere, and the workspace's own dot-paths, stay approvable")
    func ownFilesStayApprovable() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at: h.root) }
        for path in ["\(h.home)/d.md", "\(h.home)/vault/notes/a.md", "\(h.home)/Documents/x", "README.md", ".git/HEAD", ".github/ci.yml"] {
            #expect(!asks(h.gate("cat \(path)")), "cat \(path)")
            #expect(!asks(h.gate(path.hasPrefix("/") ? path : "\(h.workspace)/\(path)", tool: "read_file")), "read_file \(path)")
        }
        #expect(!asks(h.gate("rg TODO \(h.home)/notes")), "a recursive read of a plain folder")
    }

    @Test("a recursive read rooted at home or above, or following links out of the workspace, asks (the Overseer's catch)")
    func recursiveAsks() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at: h.root) }
        for command in ["rg -a BEGIN \(h.home)", "grep -r key \(h.home)", "find \(h.home) -name id_x", "ls -R \(h.home)", "du \(h.home)",
                        "find / -name id_rsa", "rg -L TODO \(h.home)/notes", "grep -R TODO \(h.home)/notes"] {
            #expect(asks(h.gate(command)), Comment(rawValue: command))
        }
    }

    @Test("a glob that could reach a hidden name under home asks", arguments: ["cat ~/.*", "cat ~/.ss*/id_*", "cat ~/*/id_rsa"])
    func globs(_ command: String) throws {
        // `isReadOnly` refuses globs today, so each of these asks either way; the shape check is the second layer.
        let h = try home(); defer { try? FileManager.default.removeItem(at: h.root) }
        #expect(asks(h.gate(command.replacingOccurrences(of: "~", with: h.home))), Comment(rawValue: command))
        #expect(SecretReadShape.asks(path: "\(h.home)/.*", cwd: h.workspace, workspace: h.workspace, home: h.home))
    }

    @Test("~ and $HOME spellings resolve to the home folder")
    func spellings() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at: h.root) }
        for path in ["~/.netrc", "$HOME/.netrc", "${HOME}/.ssh/id_ed25519"] {
            #expect(SecretReadShape.asks(path: path, cwd: h.workspace, workspace: h.workspace, home: h.home), Comment(rawValue: path))
        }
        #expect(!SecretReadShape.asks(path: "~/d.md", cwd: h.workspace, workspace: h.workspace, home: h.home))
    }
}
