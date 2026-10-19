# Installing Iris

Moved from the README, which now links here.

## Install

Requires an Apple Silicon Mac running macOS 14 or later.

Download the latest `.dmg` from [GitHub Releases](https://github.com/sackheads/iris/releases),
open it, and drag `Iris.app` to `Applications`. Run it from `/Applications`, not from the mounted
DMG: an app run from the disk image is translocated by macOS and cannot update itself. The app is
notarized, so Gatekeeper opens it without a right-click bypass; the first launch still shows
macOS's standard confirmation that it was downloaded from the Internet.

Keychain prompts appear only for secrets (API keys, etc.) that already exist from a build from
source — older source builds stored them under the installed app's Keychain items, before dev
builds moved to their own `.dev` ones. The installed app's first use of each such item prompts
once; choose "Always Allow" (one per item) so you aren't asked again. A fresh install has none and
shows no prompts.

**On a release build, a Keychain prompt for Iris at launch means something else changed its item:
click Deny.** After the first Always Allow, Iris never asks for its own item again. Since #678 that
item holds both your API keys and the settings that guard spending, where data goes, and safety:
- the provider addresses;
- the job budgets and run limits;
- the goal and subagent limits;
- the sandbox, Vibecop and prompt-injection switches;
- the providers a subagent may use besides the primary.

A command can replace that item without asking you, but Iris's next read of a replaced item asks.
Clicking Deny there leaves the item untouched, and for that launch Iris uses protective values: the
official provider addresses, built-in limits, and the sandbox, Vibecop and prompt-injection
protection on. With the sandbox on and no container runtime, it refuses commands rather than running
them on the host. A launch notice says what happened.

- **Dev builds:** they prompt routinely (each rebuilt binary is a new identity, #578), so there a
  prompt is a much weaker signal, and an Allow given out of habit accepts whatever the item holds.
- **No saved keys:** on a Mac with no saved keys (for example Gemini through `gcloud`), a command
  that deletes the item and plants old-style settings can reset a choice stricter than the built-in
  one (sandbox on, lower budgets) back to built-in, without a prompt. It can't loosen anything past
  built-in.
- **The full fix** is moving to the data protection keychain (#681).

The installed app checks for updates once a day and installs them through [Sparkle](https://sparkle-project.org) when you accept them; check
by hand with **Iris > Check for Updates…** or `/update`. See [Updates](#updates) below for detail.

Building from source instead? A dev build (`swift run`, `scripts/run-dev.sh`, or the Xcode Debug
scheme) keeps its own conversations and memory under `~/.iris-dev`, separate from the installed
app's `~/.iris`, so the two never collide. See [Building from source](building.md).

## Signing in to a provider

When started, Iris launches as a native macOS App. If you haven't configured your API keys or authentication method, the **Settings Window** will automatically pop up. 
All keys are saved securely to your local Keychain, and so are the settings that guard spending, where data goes, and safety (see above); the rest of Iris's settings live in `UserDefaults`. Gemini supports both standard API Keys and **Application Default Credentials (ADC)** via `gcloud`, and Anthropic supports an API key or **Vertex AI (ADC)**, which calls Claude models hosted in a Google Cloud project you name (the location defaults to `global`; a dated Anthropic model id is sent to Vertex in its `@`-dated spelling). See [docs/Google_ADC_credentials.md](Google_ADC_credentials.md) for step-by-step setup and GCP project configuration.

## Updates

- **Auto-Updates**: The installed app (from a release DMG) updates itself with [Sparkle](https://sparkle-project.org): it checks the signed appcast once a day, and Sparkle's own window shows the release notes and installs the update when you accept it. Check by hand with **Iris > Check for Updates…**, the menu bar item, `/update`, or **Check Now** in Settings' **Updates** tab, where you can also turn the daily check off. Dev builds (`swift run`, the Xcode Debug app) never check or update; `/update` there says so.
- **Developer & Maintainer Releases**: Instructions for building signed release bundles, publishing releases, and managing release notes can be found in [docs/releasing.md](releasing.md).
