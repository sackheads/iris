# Iris Tool Hooks

Iris features a robust, extensible Tool Hook lifecycle that allows you to intercept, observe, or block agent behaviors dynamically using arbitrary shell scripts. 

These hooks are configured via `~/.iris/settings.json`.

## Supported Hooks

The tool hook lifecycle provides granular control over the agent's interactions:

- **`SessionStart`**: Fired when a brand new conversation session is created.
- **`PreCompress`**: Fired immediately before the conversation history is summarized or compressed to save context window tokens.
- **`BeforeToolSelection`**: Fired before the LLM decides which tools are available for the current turn.
- **`BeforeModel`**: Fired immediately before the HTTP request is sent to the LLM provider (Gemini, Anthropic, or OpenAI).
- **`AfterModel`**: Fired immediately after the HTTP response is received from the LLM provider.
- **`BeforeAgent`**: Fired before the agent begins its thinking loop on a user's input.
- **`AfterAgent`**: Fired immediately after the agent finalizes its response and pushes text to the UI.
- **`BeforeTool`**: Fired before a specific tool (e.g., `run_command`, `write_file`) is executed locally. Host `run_command` invocations run with the user's login-shell PATH captured once at app launch, so shims installed by `.zprofile`/`.zshrc` (pyenv, nvm, Homebrew) resolve without spawning a login shell per command.
- **`AfterTool`**: Fired immediately after a specific tool finishes execution and returns its result.
- **`Notification`**: Fired when a system notification is triggered (e.g., from a background schedule or Vibecop alert).

### Streaming and the model/agent hooks

With **Stream responses** on (Settings), the reply is shown as it arrives: the agent row opens on
the first token and grows in place. The `AfterModel` and `AfterAgent` hooks still fire once, after
the whole reply has arrived — they never see a partial reply. A hook that rewrites the text
replaces what the user has been reading (the rewritten text is what is finally written and
persisted), and a hook that blocks leaves the streamed text in place with the block notice posted
after it.

If the turn is stopped, or the provider fails part-way through a reply, whatever streamed stays on
screen and is recorded in the conversation history as the model's turn, so the next request
reflects what the user actually saw.

### Thinking replay and rewriting hooks

"Replay Claude's thinking within a turn" (Settings, off by default) controls whether, on an
Anthropic model, Iris replays this turn's own thinking blocks back to the model across tool-call
rounds, so the model keeps its reasoning instead of starting cold each round. A paid measurement
(PR #405) found replay costs about 18% more per task on Opus 5.5 with no fewer rounds, and whether
it improves reasoning quality is unmeasured either way — hence the setting and its default. With
the setting off, every request goes without blocks, exactly as on a non-Anthropic model.

With the setting on: a `BeforeModel` or `AfterModel` hook that rewrites what was already sent, or
a `PreCompress` hook that changes history, drops every block produced up to that point: none of
them goes out again in this turn. Replay is not off for the rest of the turn, though. It resumes
with the next reply, whose blocks are sent back on the rounds after it. A `PreCompress` edit
therefore costs only the reasoning from before it.

A `BeforeModel` hook that rewrites identically every round — producing the same bytes each time —
does not count as a change and keeps replay going. An `AfterModel` rewrite always counts: a reply
the hook changed is stored without its thinking blocks, so it can never be sent back as the server
saw it. A hook that rewrites every reply therefore means no replay at all in that turn, even when
its rewrite is the same every time.

## Configuration (`~/.iris/settings.json`)

Hooks are defined under the `hooks` object, keyed by the event name. Each hook array contains a `matcher` (a regex to match the target, like a specific tool name or just the event name itself) and a list of `hooks`.

### Example `settings.json`

```json
{
  "hooks": {
    "BeforeTool": [
      {
        "matcher": "run_command",
        "hooks": [
          {
            "name": "Block dangerous rm commands",
            "type": "command",
            "command": "jq -e '.command | test(\"rm -rf /\") | not' > /dev/null || exit 2",
            "description": "Exits with status 2 to block the command if it tries to rm -rf /"
          }
        ]
      }
    ],
    "AfterAgent": [
      {
        "matcher": "AfterAgent",
        "hooks": [
          {
            "name": "Log Agent Responses",
            "type": "command",
            "command": "jq -r '.output' >> ~/.iris/agent_outputs.log"
          }
        ]
      }
    ]
  }
}
```

## Hook Payloads and Decisions

When a hook is fired, the corresponding data payload (like tool arguments, or the model response) is piped into the hook's `stdin` as a JSON string.

### Exit Codes & Decisions
The shell script's exit status code dictates how Iris proceeds:
*   **Exit `0`**: Proceed normally. If the hook outputs valid JSON to `stdout`, it acts as a **mutation**, and the payload is replaced with the modified data for the rest of the pipeline.
*   **Exit `2`**: Block execution immediately. The `stderr` output is used as the blocking reason presented to the user.
*   **Any other exit code**: Handled as a warning (logged, but execution proceeds).
*   **Killed by a signal**: Also a warning. A hook killed by SIGINT does not count as exit `2`. A hook its own timeout killed is the exception (see below).

### Timeouts and background jobs
Each hook runs as the leader of its own process group. It gets `timeout` seconds (60 when unset). After that the whole group gets SIGTERM, then SIGKILL 2 seconds later. A hook its timeout killed never gave its verdict, so its exit status is ignored, even `0` from a hook that traps SIGTERM, and it **fails closed**: on `BeforeAgent`, `BeforeModel`, `BeforeToolSelection`, `BeforeTool`, `AfterModel`, `AfterTool` and `PreCompress` it blocks, exactly as exit `2` would. This includes the `After*` and `PreCompress` events because a hook there may be redacting what goes to the provider. A slow redaction hook therefore blocks the result or the turn rather than letting the unredacted content through, and a blocked `AfterTool` result reaches the model only as the blocked message. On `Notification`, `SessionStart` and `AfterAgent`, where nothing acts on the decision, it is a warning: the hook's output is discarded. Size `timeout` for the slowest run a redaction hook can have. If the turn is cancelled while a hook runs, the hook is killed the same way and the call is blocked, since the hook never gave its verdict. A hook that exits while something it started still holds its stdout or stderr has that group SIGKILLed after 1 second, so a stray background job cannot stall the turn. To leave a job running, redirect its output (`long_job > /tmp/log 2>&1 &`).
