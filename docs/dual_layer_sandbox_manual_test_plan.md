# Dual-Layer Sandbox Routing (Piece 2a) — Manual Test Plan

Manual/GUI verification for the dual-layer sandbox routing feature. The code and unit tests are
done and reviewed; these steps cover the behaviors that need a running app + real container
runtime.

## Before you start

- Open the app **and** a Terminal window.
- In Terminal, this lists sandbox containers (run it whenever a step says "check containers"):
  ```
  /usr/local/bin/container ls -a
  ```
  Iris's containers are the ones whose name starts with `iris-`.

---

## Test A — Sandboxing OFF should look exactly like before

1. Open **Settings → Sandboxing**. Make sure **"Enable sandboxing"** is **unchecked**.
2. Start a new conversation. Ask Iris to run a shell command (e.g. *"run `whoami` and `pwd`"*).
3. **Expect:** it runs, and there is **no** `[sandbox]` warning message anywhere.
4. In Terminal, check containers. **Expect:** no new `iris-` container appeared.

Proves the "off" state is unchanged from today.

---

## Test B — The new Settings control shows up

1. In **Settings → Sandboxing**, **check "Enable sandboxing."** (If the container runtime isn't
   installed, it'll offer to install — let it.)
2. **Expect:** a new **"Main agent (default)"** picker appears, with **Host** and **Sandboxed**
   options. Leave it on **Host**.

Proves the master switch + global default picker work.

---

## Test C — The sidebar toggle (main agent, per conversation)

1. Right-click a conversation in the left sidebar.
2. **Expect:** below **"Link to Workspace…"**, **"Add Directory…"** and **"Manage Directories…"**
   (#962), then **"Sandbox main agent"** with a **checkbox**. Because the global default is Host,
   it should be **unchecked**.
3. Link that conversation to a real folder (right-click → Link to Workspace…), pick a project
   folder.
4. Right-click again → **check** "Sandbox main agent."
5. Ask Iris to run a command (e.g. *"run `uname -a`"*).
6. **Expect:** in Terminal, a new `iris-…` container now exists (that command ran inside it).
7. Right-click → **uncheck** "Sandbox main agent." Run another command.
8. **Expect:** it now runs on your Mac (host) again.

Proves the per-conversation toggle flips main-agent routing; checkmark = current state.

---

## Test D — Subagents are ALWAYS sandboxed (the whole point)

1. Keep "Enable sandboxing" **on**, global default on **Host**, and the current conversation's
   toggle **unchecked** (so the main agent is on host).
2. Ask Iris to do something that spins up a **subagent** (however you normally trigger one —
   e.g. *"delegate this to a subagent: list the files in /etc"*).
3. While/after it runs, check containers in Terminal.
4. **Expect:** a new `iris-…` container appears for the subagent — **even though the main agent
   is on host**. The subagent's work ran isolated.
5. In the sidebar, find the **"Subagent: …"** conversation it created and right-click it.
6. **Expect:** there is **NO** "Sandbox main agent" toggle on that one (subagents aren't
   user-togglable).

Proves the dual-layer: main on host, subagent sandboxed, independently.

---

## Test E — The `/sandbox` command

1. In any conversation, type **`/sandbox`** and send.
2. **Expect:** a status message showing: master switch on, runtime installed yes, this
   conversation's main-agent state (sandboxed/host) **and where it came from** (this conversation
   / workspace / global default), the global default, and "subagents always sandboxed."
3. Type **`/sandbox workspace sandboxed`** (needs a linked workspace).
4. **Expect:** a confirmation it was set for that workspace's folder.
5. Type **`/sandbox`** again.
6. **Expect:** the "source" now says it came from the **workspace**.
7. Type **`/sandbox workspace clear`**.
8. **Expect:** a message that says it **cleared** the override (should read naturally, not
   "set to clear").

Proves the status report + per-workspace override + the wording fix.

---

## Test F — No-runtime warning fires once (only if you can stop/uninstall the runtime)

*Skip if you don't want to touch the runtime.*

1. Stop the container runtime so it's "not installed/ready," but keep "Enable sandboxing" on and
   a conversation set to sandboxed.
2. Run a command.
3. **Expect:** exactly one `[sandbox] No container runtime available — running on the host
   WITHOUT isolation…` message, then it runs on host.
4. Run a **second** command in the **same** conversation.
5. **Expect:** it runs on host but does **NOT** repeat the warning (once per conversation).

Proves the graceful fallback + one-time warning.

---

## Optional — Migration (advanced)

This only matters for the *upgrade* path. If you had `enableSandboxing` **on** before this
change, then after first launch the **global default picker should read "Sandboxed"** (your old
behavior preserved). Fresh installs read "Host." You can eyeball it in Settings; no action
needed.

---

If any step misbehaves, note the test letter + what you saw.
