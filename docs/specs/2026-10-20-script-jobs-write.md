# Script jobs that write (#688)

**Status:** spec, iris-dev-1, 2026-10-20, from the planner's brief. The planner ruled forks 1-5 and the one-resolver question on 2026-10-20; the rulings are recorded under each. This is spec only: the build starts after #698 (script jobs, #330) merges, and builds on it. Reviewers: iris-dev-2 and iris-dev-3 (sandbox, mounts and approvals).

## What and why

#330's v1 (`docs/specs/2026-10-19-script-jobs.md`, fork A) runs a script job with **read-only** mounts only. That covers checks, digests and "is X up". It leaves out every job that changes something: the Downloads sweep, rotating logs, `git pull` in a mirror, writing a report file where the next fire can read it.

This spec adds a script job on a **mutating job's grant**: read-write mounts, under every rule a mutating prompt job's grant already has. The new risk is the one #688 names. A script that writes runs on every fire, unattended, with no model in the loop to notice a mistake. The person approves it once, and from then on it runs as written, against whatever is in the mount.

## The shape

- **Creating one.** `schedule_job` with `script` and `profile: "mutating"`, plus the grant's own `mounts` and `network`, the same arguments a mutating prompt job takes (Grants, `docs/jobs.md`). No new argument.
  - `script_mounts` and `script_network` stay the read-only job's arguments. Given together with `profile: "mutating"`, they're refused with one sentence: "a writing script job takes its folders and network from `mounts` and `network`, as any mutating job does".
  - One resolver means one set of rules: `JobGrant.resolve`, never a second copy. **Ruled (planner): one resolver.** A mutating script job takes its grant's `mounts` and `network`.
- **What the grant already enforces**, unchanged and in force for scripts:
  - a read-write mount's own `.iris/` mounted read-only over it (#617), and so is the `.git/hooks` of a repository at its root (#623);
  - credential stores, startup locations, home and above, and Iris's own folders refused;
  - **#616 (#710):** a read-write mount on, inside or holding a login-PATH folder refused, and every read-write mount recorded in the writable-roots record before a container exists (a record that can't be written refuses the run);
  - `JobGrant.drift` re-checked at every fire.
- **Network.** The grant's `network` (`NetworkMode.forGrant`): off, meaning the host-only isolated network (#690), unless the job asks. That matches #330's B: off by default, and asking for it is shown in the review.
- **Running it.** #330's fire path (a fresh container per run, `LiveContainerNames`, the dispatch-clock watchdog, the in-VM group kill, the sweep on every exit), with the grant's mounts read-write. Output goes through #699's bounded drain (`exec(…, outputLimit:)`): 128 KB a stream on the host, above #698's in-VM 64 KB and its marker.
- **Git in a writable mount.** Like a sandbox session (#623), the run's container joins `GitConfigGuard`:
  - `watch(owner:sources:)` on the read-write mounts before the exec, and `check(owner:)` after it;
  - a disallowed change is put back, and that run is `failed` with the guard's notice as its outcome;
  - the check runs on **every exit**, including a timeout kill and a cancel: it rides the sweep, before the guard's `end(owner:)`, and a finding on a killed run is reported with the timeout;
  - **nested repositories** under a read-write mount: the guard and the read-only `.git/hooks` overlay cover the repository at the mount's root, as for a sandbox session. A nested one's hooks are writable, which is the dialog's "a nested repository's hooks" in fork 2's warning. It doesn't list them, since a scan could be large. docs/jobs.md says to mount the repository itself, not a folder of them, when its hooks matter.

  There's no `SandboxGitSync`: a script job's commits stay in the mount, where the script made them. Host git there is held to the guard's rules, as it is after any sandboxed write.

## Forks

### 1. What the review must show for writes

**Settled:** human-only at creation, as for every script (#330 B). Vibecop advises, its APPROVE doesn't count, and there's no Always Allow. A change to the script, the mounts, any mount's read-only flag, the network or the profile re-asks.

**Open: what the dialog says.** My proposal:
- **The script, whole**, then each mount as `source → target, read-write` or `read-only`, then the network and the timeout. That's #652's mutating-job dialog plus #330's script block.
- **A sentence for writes, always:** "This script can change and delete files in <read-write mounts> on every run, with no one watching. A mistake repeats on every fire until you pause the job."
- **With network on, added:** "It can also reach the internet, so it could download something and write it into those folders, or send what's in them anywhere."
- **With network off:** "It can still reach services on this Mac" (#690's wording from #330).
- **The disk floor** from fork 4, as one line: "It won't run while the disk holding these folders has less than 5 GB free." And a note for any mount too large to measure (fork 4).

**Ruled: as above** (planner). The point is that the person reads "change and delete" next to the folder names before they click, and not only a grant table.

### 2. Should a mounted file changing force a re-review?

#698's fingerprint (the script, mounts, network and timeout, kept in the Keychain) catches the *stored job* changing outside Iris. The question is whether a writing script should also re-ask when the *mounted content* changes.

**Lean: no**, for three reasons:
- **It can't work.** The script writes into its own mounts, so its first run changes the content and the second fire would pause for review. A re-review on content change would pause every writing job after one run.
- **The mounts are the input.** "Sweep `.dmg` files older than a week" is meant to act on whatever is there. Reviewing the script is reviewing what it does to any content, which is what a person can judge.
- **The real hole is narrower**, and it's #330's known limit made worse: a script that **executes a file from a read-write mount** (`sh /mnt/repo/tidy.sh`) runs whatever that file holds, and the script can rewrite that file itself. So what runs on the next fire can be content no one reviewed.
  - I don't propose to parse shell to catch it.
  - The dialog adds, when any mount is read-write: "If this script runs, or reads instructions from, a file in these folders (`sh`, `source`, `python`, `make`, a nested repository's hooks), that file can change between runs, and it will be used as it is then." docs/jobs.md says the same, with the advice to keep the logic in the script itself.

**Ruled: no content re-review; the fingerprint gains each mount's read-only flag and the profile** (planner).

**What the fingerprint must gain** (dev-2 and dev-3, #721 review): a writing job's folders come from the grant, which #698 doesn't fingerprint at all, so the fingerprint takes **the grant's mounts (source, target, read-only) and its network, plus the profile**. A read-only job's `script_mounts` strings already carry `:ro`, so they need nothing new.
- **The encoding is additive.** Each new input is written only when it differs from its default (no grant, profile `readOnly`). So a read-only script job with no grant hashes **byte-identically** to #698's v1, nothing is re-asked on upgrade, and there's no re-fingerprint pass to replay (#698's TOFU hazard).
- A test pins the byte-identical v1 hash for a read-only job. Then turning a read-only mount read-write, outside Iris or through a re-schedule, is "changed since review", never a silent widening. A test pins it: flipping one mount's flag in the stored row pauses the next fire.

### 3. Do #330's card rules still fit?

#330 C posts a card on a change or a failure, judged on the exit status and the outcome line. The first run always posts.

**Ruled: keep them** (planner). A writing job's outcome line is its own summary ("moved 3 files", "rotated 2 logs"), so a run that did something different prints a different line and posts. A sweep that finds nothing to do stays quiet, which is the point of the rule. Two additions:
- **A git-guard finding** (above) is a failure, so it always posts.
- **A disk-floor refusal** (fork 4) is `interrupted` with its reason, and it posts the first time, like the "no container runtime" refusal.

A person who wants a card every run can print a line that always changes, such as a timestamp. The docs say so.

### 4. What stops a runaway writer?

The danger is a script that fills the disk (a loop that appends, or a `cp` into itself) or deletes more than it should. Already bounded today:
- **Duration:** `script_timeout_seconds`, 5-3600 s, killed in the VM.
- **Frequency:** the breaker (runs per hour), overlap (never concurrent with itself) and the retry ladder.
- **Reach:** the grant's mounts only, never the host. The rules refuse home, startup locations, credential stores, the login PATH and Iris's folders.

**There's no per-run quota mechanism.** Writes cross virtiofs straight onto the host volume, so the VM can't cap them, and the host can't account for them per container.

**Why not the volume** (dev-3, the planner's revision): volume-wide free space moves for reasons that have nothing to do with the job. This Mac went from 28 to 64 GB free during one night's cleanup, Time Machine thinning and purgeable space free gigabytes on their own, and a Swift build takes 9 GB. Pausing on volume deltas would stop healthy writers over and over, which is the notice fatigue #706 removed. A percentage floor fails the same way: 5% of a 1 TB disk is 50 GB, more than this Mac often has free.

**Ruled (planner, revised 2026-10-20):**
- **A fixed volume floor, before every fire.** Each read-write mount's volume (`statfs`) must have at least **5 GB** free, or the fire is `interrupted` with "the disk holding <mount> has only X free".
- **A capped walk of each read-write mount, before and after the run.** It counts files and sums bytes, follows no symlinks and stays on one filesystem. It stops at **200,000 entries or 2 s**, whichever comes first, with the 2 s timed on `UptimeClock`, so a sleep mid-walk isn't counted (#608). This measures the job's own folders, so nothing else on the volume moves the figures.
- **Pause, with a card, when a run:**
  - grew a mount by more than `max(2 GB, 100%)` ("this run added X to <mount>; paused so you can look");
  - shrank its bytes by more than `max(1 GB, 20%)`, or dropped its file count by more than `max(1000, 20%)` ("this run removed N files (X) from <mount>; it may have deleted more than it should"). The file count is the better deletion signal, since a delete of many small files barely moves the bytes.

  A paused job needs a human resume.
- **A walk that hits its cap** skips that mount's growth and shrink checks for that run. The creation dialog runs one trial walk per read-write mount and says so once ("<mount> is too large to measure quickly, so Iris won't notice if a run fills or empties it"). A later run that's capped for the first time says it once on its card.
- **The figures go on the run's ledger row:** each mount's before and after entry count and bytes, or "capped". That's a new `JobRun` field, read with `decodeIfPresent` (Invariant 1), and it lets a person see after the fact what a run did to its folders.
- **Within one run,** the bound is still the timeout (at most an hour). A watchdog that polls during the run is the follow-up if a measured case shows a single run doing real harm in under an hour.
- **Deletion** is bounded roughly by the shrink and count checks, which catch a large delete after the run that did it. Its other bounds are the grant rules, the dialog's "change and delete" sentence, and the person's backups. The docs say so plainly.

### 5. #690's host-only network, combined with writes

"Network off" is the isolated network, which can still reach services on the Mac (#690). For a read-only script that's a way to *send* (#330 B's reason for human-only review). With writes, it's also a way to *receive*: a script could fetch from a local service and write the result into a mounted repository, where the person's tools later run it.

**Ruled: no new rule** (planner).
- **The review is already human-only**, and the dialog's network-off line says "can still reach services on this Mac". This spec adds "and write what it gets into these folders" when a mount is read-write.
- **The content is the reviewed script's choice.** A local service can feed only a script written to ask it, and the person read that script.
- **When #691** (a true no-network mode via `unshare --net` in the VM) passes the real-VM check, "off" means off for writing scripts too. Nothing here depends on it.

## Invariants

- **Invariant 4.** Unchanged from #330: the container joins `LiveContainerNames`, the deadline is the dispatch watchdog, the kill happens in the VM, and the sweep runs on every exit. The `GitConfigGuard` `end` rides the sweep. The fork 4 walks are blocking file I/O, so they run off the cooperative pool (`OffPool`), each bounded by its own 2 s cap, before the container is created and after it's swept, so no walk sits inside the run's deadline.
- **Invariant 1.** One new persisted field, the run's mount figures (fork 4): a `job_runs` column added by a migration numbered in merge order, and read with `decodeIfPresent`. Otherwise nothing beyond #330's. The profile and grant are existing `Job` fields. The fingerprint's new inputs (the read-only flags, the profile) change its *value*, not a schema.
  - **Upgrading changes nothing.** The new inputs are written only away from their defaults, so every #698 script job, all of them read-only, hashes as it did. Nothing is re-asked, and there is no marker or re-fingerprint pass, which would be #698's trust-on-first-use replay (dev-2 and dev-3).
- **Invariant 6.** No new tool and no new argument.
- **Invariant 9**, the sentences to search for when it's built:
  - #330's "script jobs are read-only" lines in docs/jobs.md;
  - the `schedule_job` description's `script` text (agent-facing), which gains "with `profile: mutating`, its `mounts` may be read-write";
  - the review dialog strings.

## Tests

- **Fake runtime**, in the default suite:
  - creation refusals: `script_mounts` or `script_network` with mutating; a read-write mount on the login PATH; a credential store; no runtime;
  - the writable-roots record written before the container, and refused when it can't be written;
  - the dialog text for each network and mount combination;
  - human-only with no Always Allow, even when Vibecop approves;
  - the fingerprint covering read-only flags and the profile (flipping a flag in the row pauses the next fire);
  - the 5 GB floor (an injected `statfs`) refusing a fire;
  - the capped walk (injected entries and clock): growth, byte shrink and file-count drop each pausing with their card, a capped walk skipping the checks and saying so once, and the figures on the row;
  - a git-guard finding failing the run and posting;
  - the card rules unchanged;
  - an older build's rows still decoding.
- **Real VM** (rule 29, through the planner):
  1. A writing script changes a file in a read-write mount, and the change is on the host.
  2. The mount's `.iris/`, and the `.git/hooks` of a repository at its root, refuse a write.
  3. A script that writes `.git/config` keys outside the guard's allowance has them put back, and the run is `failed`.
  4. The timeout kills a writer mid-loop, leaving no process and no container.

## Scope

Closes #688. Built after #698. Uses #699's bounded drain and #710's record and login-PATH rule. If either hasn't merged when the build starts, it waits for them rather than stacking.

## Out of scope

- A per-run byte quota (fork 4 (c)), and a delete counter.
- Host scripts (#330 F).
- Relaxing review for any writing script, however simple.
- `SandboxGitSync` for script jobs (commits stay in the mount).
