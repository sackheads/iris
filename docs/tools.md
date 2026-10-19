# Core native tools

Moved from the feature tour ([docs/features.md](features.md)), word for word (#534).

Iris provides some native primitives to the LLM:
1.  `run_command`: Sandboxed execution of shell commands (runs in a lightweight Linux VM via `apple/container` if sandboxing is enabled). Host commands run with the user's login-shell PATH captured at launch, so pyenv/nvm/Homebrew shims resolve even though the command itself isn't run in a login shell. Its `timeout_seconds` (10 s to 1 h, 10 minutes by default) bounds the command in the VM exactly as it does on the host — the command, and everything it started, is killed at the deadline (SIGTERM, then SIGKILL two seconds later) and reported as timed out in the same words, and the container session survives it. Stop kills it the same way. On the host, a background process that is still writing to the command's output when the command exits is killed then too; one whose output is redirected (`server > log 2>&1 &`) keeps running.
2.  `read_file`: Reads arbitrary local text files; given a directory, lists its entries one level deep, dotfiles included.
3.  `write_file`: Writes/modifies local files.
4.  `schedule_job`: Creates a recurring job in the conversation database: a five-field `cron` expression with an optional IANA `timezone`, an `intervalSeconds` interval, or the loose `minute`/`hour`/`weekday`/`weekdays` fields (`[2,3,4,5,6]` for every weekday), plus an optional `profile` (`readOnly` by default, or `mutating` for a job that must change something), an optional gate (`gate_url`, `gate_path`, or `gate_script` with `gate_mounts`, `gate_timeout_seconds` and `gate_network`, always reviewed by you) so the job only runs when something changed, the two policies `overlap` (`skip`/`queue`) and `catch_up` (`coalesce`/`skip`/`replay:N`), and a per-job run timeout `timeout_seconds` (60-3600, overriding the global setting for that job). Jobs survive restarts. Each fire runs in the background and reports back with a card in Iris, your pinned main conversation — calling this tool from Iris itself asks you to approve the job first.
5.  `set_workspace`: Automatically binds the active conversation to a project path.
6.  `reflect`: Internal tool allowing the agent to write down its reasoning, plans, and self-evaluations during complex loops.
7.  `goal_complete`: Escapes an active autonomous `/goal` loop.
