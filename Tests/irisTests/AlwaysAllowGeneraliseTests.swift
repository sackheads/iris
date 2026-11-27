import Foundation
import Testing
@testable import IrisKit

/// #1428: what Always Allow offers for the shapes a dev fleet runs, and that each saved rule covers the next call of
/// that shape but none of the hazards beside it. Every rule here goes through a real `PermissionManager` on disk.
@Suite("Always Allow generalises the fleet's commands and offers nothing for one-offs (#1428)")
struct AlwaysAllowGeneraliseTests {
    struct Rig {
        let root: URL
        let workspace: String
        let sibling: String
        let permissions: PermissionManager

        init() throws {
            root = URL(fileURLWithPath: IrisPaths.realPath(FileManager.default.temporaryDirectory.path))
                .appendingPathComponent("iris-1428-\(UUID().uuidString)")
            workspace = root.appendingPathComponent("iris").path
            sibling = root.appendingPathComponent("iris-sib").path
            let fm = FileManager.default
            for dir in [workspace + "/scripts", workspace + "/Sources/scripts", sibling, root.path + "/outside"] {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            for file in ["scripts/test-filter.sh", "scripts/check-warnings.sh", "scripts/other.sh", "Sources/scripts/test-filter.sh"] {
                try "#!/bin/sh\n".write(toFile: workspace + "/" + file, atomically: true, encoding: .utf8)
            }
            try "#!/bin/sh\n".write(toFile: root.path + "/outside/evil.sh", atomically: true, encoding: .utf8)
            try fm.createSymbolicLink(atPath: workspace + "/scripts/link.sh", withDestinationPath: root.path + "/outside/evil.sh")
            let paths = IrisPaths(root: root.appendingPathComponent("home"))
            try paths.ensureDirectories()
            permissions = PermissionManager(paths: paths)
        }

        func offer(_ command: String) -> (rules: [PermissionRule], withheld: String?) {
            PermissionRule.alwaysAllowOffer(toolName: "run_command", details: command, workspace: workspace)
        }

        /// Saves what Always Allow offers for `command` (a script's rule in the project, as the dialog's project button
        /// does; everything else globally), then reads the allowlist back from disk as a relaunch would.
        func save(_ command: String) -> PermissionManager {
            let rules = offer(command).rules
            if rules.contains(where: \.isScriptPrefix) {
                permissions.allowInProject(rules, workspace: workspace)
            } else {
                permissions.allowGlobally(rules)
            }
            return PermissionManager(paths: permissions.paths)
        }

        func allowed(_ manager: PermissionManager, _ command: String, in workspace: String? = nil) -> Bool {
            manager.isAllowed(toolName: "run_command", details: command, workspace: workspace ?? self.workspace, isOwner: true)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private func prefixes(_ rules: [PermissionRule]) -> [String] { rules.filter(\.isPrefix).map(\.details) }

    // MARK: The planner's rows

    @Test("a cd inside the workspace saves the main command's prefix, which covers the next identical call")
    func cdInside() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let command = "cd Sources && swift build"
        #expect(prefixes(rig.offer(command).rules) == ["swift build"] && rig.offer(command).withheld == nil)
        let next = rig.save(command)
        #expect(rig.allowed(next, command))
        #expect(rig.allowed(next, "swift build -c release"))
    }

    @Test("a cd to a sibling worktree offers Allow once only, with the note to set the workspace")
    func cdSibling() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let offer = rig.offer("cd ../iris-sib && swift build")
        #expect(offer.rules.isEmpty && offer.withheld == ToolApprovalRequest.leavesWorkspaceMessage)
        #expect(rig.offer("cd \(rig.sibling) && swift build").withheld == ToolApprovalRequest.leavesWorkspaceMessage)
    }

    @Test("a chain with a command that has no prefix offers Allow once only, never its exact text",
          arguments: ["swift test | tail && git push", "swift build && git push -u origin dev3/x", "cd Sources && gh api repos/a/b"])
    func oneOffChain(command: String) throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let offer = rig.offer(command)
        #expect(offer.rules.isEmpty && offer.withheld == ToolApprovalRequest.oneOffChainMessage, Comment(rawValue: command))
    }

    @Test("a single command keeps today's offer: its prefix, or its exact text when it has none or the prefix can't cover it")
    func singleUnchanged() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        #expect(prefixes(rig.offer("swift test --filter Foo").rules) == ["swift test"])
        for exact in ["git push -u origin dev3/x", "gh api repos/a/b/pulls", "ls /etc"] {
            let offer = rig.offer(exact)
            #expect(offer.rules == [PermissionRule(toolName: "run_command", details: exact)] && offer.withheld == nil, Comment(rawValue: exact))
        }
    }

    // MARK: Workspace scripts

    @Test("a workspace script's rule covers any arguments and the pipes swift test gets")
    func scriptGeneralises() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        #expect(prefixes(rig.offer("scripts/test-filter.sh FooTests").rules) == ["scripts/test-filter.sh"])
        let next = rig.save("scripts/test-filter.sh FooTests")
        for command in ["scripts/test-filter.sh BarTests", "./scripts/test-filter.sh BarTests",
                        "scripts/test-filter.sh BarTests 2>&1 | grep -E 'Test run' | tail -1"] {
            #expect(rig.allowed(next, command), Comment(rawValue: command))
        }
        let warnings = rig.save("scripts/check-warnings.sh")
        #expect(rig.allowed(warnings, "scripts/check-warnings.sh 2>&1 | tail -3"))
    }

    @Test("a script rule covers only that path in the workspace: never another script, a cd'd spelling, a link out, or a path outside")
    func scriptHazards() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let next = rig.save("scripts/test-filter.sh FooTests")
        for command in ["scripts/other.sh", "cd Sources && scripts/test-filter.sh X", "\(rig.workspace)/scripts/test-filter.sh X",
                        "../iris/scripts/test-filter.sh X", "scripts/../scripts/test-filter.sh X"] {
            #expect(!rig.allowed(next, command), Comment(rawValue: command))
        }
        #expect(rig.offer("scripts/link.sh").rules == [PermissionRule(toolName: "run_command", details: "scripts/link.sh")],
                "a link out of the workspace gets no prefix, only its exact text")
        #expect(CommandPattern.workspaceScript("scripts/x.sh") == "scripts/x.sh" && CommandPattern.workspaceScript("./scripts/x.sh") == "scripts/x.sh")
        for bad in ["/bin/x.sh", "~/x.sh", "../x/y.sh", "a//b.sh", "a/./b.sh", "x.sh"] {
            #expect(CommandPattern.workspaceScript(bad) == nil, Comment(rawValue: bad))
        }
    }

    @Test("a script rule is per project: repo B's same-named script isn't covered, a global one never matches, and no workspace is Allow once")
    func scriptPerProject() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let repoB = rig.root.appendingPathComponent("other-repo").path
        try FileManager.default.createDirectory(atPath: repoB + "/scripts", withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(toFile: repoB + "/scripts/test-filter.sh", atomically: true, encoding: .utf8)
        let next = rig.save("scripts/test-filter.sh FooTests")
        #expect(rig.allowed(next, "scripts/test-filter.sh BarTests"))
        #expect(!rig.allowed(next, "scripts/test-filter.sh BarTests", in: repoB))
        rig.permissions.allowGlobally([PermissionRule(toolName: "run_command", details: "scripts/test-filter.sh", match: .prefix)])
        #expect(!rig.allowed(PermissionManager(paths: rig.permissions.paths), "scripts/test-filter.sh X", in: repoB),
                "a global script prefix, even hand-written, matches nothing")
        let none = PermissionRule.alwaysAllowOffer(toolName: "run_command", details: "scripts/test-filter.sh X", workspace: nil)
        #expect(none.rules.isEmpty && none.withheld == ToolApprovalRequest.scriptNeedsWorkspaceMessage)
    }

    // MARK: git rebase

    @Test("a git rebase rule covers another upstream")
    func rebaseGeneralises() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        #expect(prefixes(rig.offer("git rebase origin/main").rules) == ["git rebase"])
        let next = rig.save("git rebase origin/main")
        #expect(rig.allowed(next, "git rebase origin/feature"))
        for command in ["git rebase --onto origin/main HEAD~2", "git rebase --onto origin/main feature HEAD",
                        "git rebase --continue", "git rebase --abort", "git rebase --skip"] {
            #expect(rig.allowed(next, command), Comment(rawValue: command))
        }
    }

    @Test("a git rebase with any option off the allowlist is never covered and gets no prefix: the class is closed", arguments: [
        "git rebase --exec make origin/main", "git rebase --ex=make origin/main", "git rebase --in origin/main",
        "git rebase --edit-todo", "git rebase -x make origin/main", "git rebase -i origin/main", "git rebase -s ours origin/main",
        "git rebase -Xours origin/main", "git rebase --strategy=ours origin/main", "git rebase --onto=origin/main HEAD~2",
        "git rebase --autosquash origin/main", "git rebase -S origin/main",
    ])
    func rebaseHazards(command: String) throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let next = rig.save("git rebase origin/main")
        #expect(!rig.allowed(next, command))
        #expect(prefixes(rig.offer(command).rules).isEmpty)
    }

    // MARK: git worktree add

    @Test("a git worktree add rule covers another worktree beside the workspace")
    func worktreeGeneralises() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        #expect(prefixes(rig.offer("git worktree add ../iris-x origin/main").rules) == ["git worktree add"])
        let next = rig.save("git worktree add ../iris-x origin/main")
        for command in ["git worktree add ../iris-y origin/main", "git worktree add -b dev3/z ../iris-z origin/main",
                        "git worktree add --detach ../iris-w abc123", "git worktree add \(rig.root.path)/iris-v", "git worktree add build/wt"] {
            #expect(rig.allowed(next, command), Comment(rawValue: command))
        }
    }

    @Test("a git worktree add outside the workspace's parent, or with an option this doesn't know, stays a prompt; other worktree verbs get no prefix")
    func worktreeHazards() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let next = rig.save("git worktree add ../iris-x origin/main")
        for command in ["git worktree add ../other", "git worktree add /tmp/x", "git worktree add ../../x", "git worktree add --unknown ../x",
                        "git worktree add", "cd Sources && git worktree add ../../../x", "git worktree add -f ../x",
                        "git worktree add -B dev3/x ../x", "git worktree add --lock ../x", "git worktree add -b -x ../x",
                        // #1436: a sibling path the target check allows, so only -b's value check refuses it.
                        "git worktree add -b -x ../iris-x",
                        "git worktree add ../x origin/main extra", "git worktree add -- ../x"] {
            #expect(!rig.allowed(next, command), Comment(rawValue: command))
        }
        for verb in ["git worktree remove ../x", "git worktree prune", "git worktree move ../x ../y"] {
            #expect(prefixes(rig.offer(verb).rules).isEmpty, Comment(rawValue: verb))
        }
    }

    @Test("a worktree goes only to a <workspace>-* sibling or a plain folder inside the workspace, after resolving links (#1434 rulings)")
    func worktreeTargets() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let ws = rig.workspace, home = "/nowhere/home"
        try FileManager.default.createSymbolicLink(atPath: rig.root.path + "/iris-link", withDestinationPath: rig.root.path + "/outside")
        for ok in ["../iris-x", "../iris-1434", "build/wt", "\(rig.root.path)/iris-y"] {
            #expect(CommandPattern.worktreeTargetAllowed(ok, cwd: ws, workspaceReal: ws, home: home), Comment(rawValue: ok))
        }
        for bad in ["../other", "../iris-x/deeper", "../iris-", "../iris", "../.vim/pack/evil/start/p", "../.hidden", ".git/wt",
                    "build/.cache/wt", "../../iris-x", "/tmp/x", "~/iris-x", "../iris-link", "../iris-link/x",
                    "\(rig.root.path)/iris-link", "\(rig.root.path)/iris-link/x"] {
            #expect(!CommandPattern.worktreeTargetAllowed(bad, cwd: ws, workspaceReal: ws, home: home), Comment(rawValue: bad))
        }
        // A workspace directly in home: its siblings are home's own folders. And one that is home: its parent is above it.
        let parent = (ws as NSString).deletingLastPathComponent
        #expect(!CommandPattern.worktreeTargetAllowed("../iris-x", cwd: ws, workspaceReal: ws, home: parent))
        #expect(!CommandPattern.worktreeTargetAllowed("../iris-x", cwd: ws, workspaceReal: ws, home: ws))
        #expect(CommandPattern.worktreeTargetAllowed("wt", cwd: ws, workspaceReal: ws, home: parent), "inside the workspace still goes")
    }

    @Test("git push and gh api stay exact")
    func pushStaysExact() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let next = rig.save("git push -u origin dev3/one")
        #expect(!rig.allowed(next, "git push -u origin dev3/two"))
        #expect(rig.allowed(next, "git push -u origin dev3/one"))
    }
}
