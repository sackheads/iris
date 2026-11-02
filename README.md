# Iris

Iris is a native macOS AI assistant: a compiled, local-first agent harness that sits between your Mac and the cloud models (Gemini, Claude and OpenAI).  It's one signed app, built on Apple's own frameworks - no Node, no Python, no `npm install`, nothing your endpoint management is likely to block.  If your work laptop won't run the usual agent tools, it will probably run this.

![Iris Screenshot](assets/screenshot_1.jpg)
<br/>
![Setup Wizard](assets/wizard.jpg)

## Why it's worth a look

- **It does real work, and stops when you say so.**  Shell commands can run in a lightweight Linux VM (`apple/container`) instead of on your Mac, and Stop or a timeout ends the command and everything it started, not just the shell.  [Details](docs/features.md#subagent-sandboxing)
- **Goals it can't fake finishing.**  `/goal` drafts a contract (what "done" means) for you to approve, then works on it on its own.  An independent grader checks the result before Iris is allowed to call it done, and anything only a person can judge comes back to you.  [Details](docs/features.md#deterministic-done-gates)
- **Background jobs.**  Run a prompt on a cron schedule, or whenever a folder changes.  Each run happens in a hidden conversation of its own and reports back with a card.  Jobs are read-only unless you say otherwise, and a call nobody was there to approve waits on the card for your click.  [Details](docs/jobs.md)
- **Memory you can read.**  Long-term memory, skills and rules are plain Markdown files under `~/.iris`, so you can read them, edit them and back them up like anything else.  [Details](docs/features.md#memory-and-skills)
- **Plays well with others.**  MCP servers, installable plugins, Google Workspace (Calendar, Docs, Drive, Sheets, Gmail, Tasks) with no extra dependencies, and conversations that can message each other.  [Details](docs/features.md#plugins)
- **Guards at the door.**  Untrusted text goes through a tiered prompt-injection guard, and an optional guardian model (Vibecop, local or cloud) can pre-screen commands so routine reads don't need your click.  [Details](docs/features.md#vibecop-guardian)

The [full feature tour](docs/features.md) has the rest: streaming replies, steering a turn while it runs, delegation to graded subagents, checkpoints, the menu bar status item and a good deal more.

## Install

Apple Silicon, macOS 14 or later.

Download the `.dmg` from [GitHub Releases](https://github.com/sackheads/iris/releases), drag `Iris.app` to `Applications` and run it from there.  (Not from the mounted disk image: macOS won't let it update itself from there.)  It's notarized, and it keeps itself up to date through Sparkle.  The details, including Keychain prompts and updates, are in [docs/install.md](docs/install.md).

## Two-minute first run

1. Launch Iris.  If no provider is set up yet, Settings opens on its own.
2. Pick a provider and paste an API key.  (Gemini can also use your `gcloud` login, and Claude can go through Vertex AI.  See [docs/install.md](docs/install.md#signing-in-to-a-provider).)  Keys go in your Keychain.
3. Press **`Cmd + Shift + Space`** from any app to bring Iris up.
4. Ask it something.  Then try:
   - `/goal` plus something you actually want done, and look over the contract it drafts before you approve it
   - asking it to schedule a job (from Iris, your main conversation, it asks you to approve the job before it exists)
   - `/search` across everything said in your past conversations, Iris's side included

Every slash command is in [docs/slash_commands.md](docs/slash_commands.md).

## More

- [Feature tour](docs/features.md): everything, one heading per feature
- [Jobs](docs/jobs.md): schedules, watches, grants, gates and `iris --run-job`
- [Plugins](docs/ipf/authoring.md): writing one, and the [format spec](docs/ipf/spec.md)
- [Google Workspace setup](docs/google_workspace_oauth_setup.md) and [Google ADC credentials](docs/Google_ADC_credentials.md)
- [Building from source](docs/building.md), including the headless `--bench` and `--run-job` modes
- [Releasing](docs/releasing.md), for maintainers
- [AGENTS.md](AGENTS.md), if you (or your agent) are going to change the code

Iris's working habits - brainstorm first, write the design down, plan, test first - come from [obra/superpowers](https://github.com/obra/superpowers).  [More on that](docs/features.md#inspiration).

Iris is released under the [MIT License](LICENSE). The software it bundles keeps its own licences: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
