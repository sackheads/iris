# Guarded settings (#678)

**Status:** fork note, iris-dev-3, 2026-10-19, with the planner's rulings folded in. Code waits for the probe's answers.

## The property

A setting that guards spend, or where data goes, can't be changed by a host command the agent runs. The test is: **one approved `defaults write` changes nothing Iris uses.** Three things follow from it:
- **A change made in Settings applies.**
- **A `defaults write` doesn't apply,** and Iris says once that it didn't.
- **A deleted store fails safe:** to shipped defaults, never to the values in the defaults domain.

## Covered settings

- **Where data goes:** `GEMINI_BASE_URL`, `ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`.
- **Spend:** `JOB_PER_RUN_TOKEN_BUDGET`, `JOB_DAILY_TOKEN_BUDGET`, `JOB_GLOBAL_DAILY_TOKEN_BUDGET`.
- **#239 half 1 joins the same mechanism** for its custom-endpoint list (URLs), its "Usable by subagents" switches, and later its typed rates.
- **Other spend caps** (planner: every setting that caps spend joins without asking). I found them by grepping ConfigManager for limits on runs, iterations, subagents and turns:
  - `JOB_MAX_RUNS_PER_HOUR`, `JOB_MAX_RUNS_PER_HOUR_WATCH`, `JOB_RUN_TIMEOUT_SECONDS`: runs and their length.
  - `MAX_GOAL_ITERATIONS`: a goal loop's reprompts, each a full model round.
  - `MAX_SUBAGENT_ITERATIONS` and `SUBAGENT_TURN_TIMEOUT_SECONDS`: a subagent's rounds, charged to whoever delegated it, and their length.
  - `MAX_DONE_GATE_RETRIES`: graded retries.
  - `MAX_SESSION_CASCADE`: the hop depth of a peer-message chain, where each hop is a turn somewhere.
  - **Left out**, as neither spend nor egress: `REPLAY_THINKING_WITHIN_TURN` (behaviour) and `SANDBOX_IDLE_TIMEOUT_MINUTES` (when an idle container stops). `VIBECOP_TIMEOUT_SECONDS` sets a guard's timing, so it waits on Brian with the guard switches.
- **Waiting on Brian:** `ENABLE_SANDBOXING`, `ENABLE_VIBECOP`, `ENABLE_PROMPT_INJECTION_PROTECTION`. The mechanism is a generic set, so each is one line once he answers.

## Fork 1: where the authoritative values live

### Option A (the planner's lean): the existing secrets item

The values go in `com.iris.secrets` (with its `.dev` suffix), in the same dict as the API keys.
- **Costs nothing new:** it's read at launch already, so there are no new prompts, and the seeder copies it whole.
- **Settings writes go there.**
- **Migration, once, and only into an item that exists.** On the first launch of this version, if the item exists and has no `GUARDED_SETTINGS_V1` marker, the old defaults values are copied in, the marker is set, and the defaults keys are deleted. After that, defaults are never read for a guarded key.
  - **An item that's missing is never migrated into,** and the defaults keys are ignored. A deleted item can't be refilled from a `defaults write`.
  - **The cost:** a person with no stored keys has no item. Gemini over ADC is the common case, and it's how the work laptop runs. They lose their custom budgets, limits and base URLs once. **It isn't silent** (planner): a one-time notice names each guarded key that was in defaults and wasn't carried over: "These settings were not carried over and are back to their defaults: JOB_DAILY_TOKEN_BUDGET, OPENAI_BASE_URL. Set them again in Settings." It names keys, never values, and it's tested.
  - **From then on, Settings creates the item** on the first write of any guarded value, keys or not.
- **A key that reappears in defaults is ignored,** with a one-time notice: "A setting was changed outside Settings and was not applied: OPENAI_BASE_URL." The notice names the key, never the value.
- **A missing item fails safe:**
  - base URLs empty, meaning each provider's own endpoint;
  - budgets at the shipped defaults;
  - no custom endpoints, and every "Usable by subagents" switch off;
  - a one-time notice that Iris's saved settings were missing and were reset.

  The API keys are gone anyway in that case, which the person will see.

**The premise A depends on is unverified.** It holds only if a host process can't replace that item without a prompt.
- **What I've confirmed:** Iris's item is a plain file-based keychain item, created by `SecItemAdd` with no explicit access object (KeychainManager.swift:76-87). Apple's TN3137 confirms that the `security` tool works only on the file-based keychain, and that the data protection keychain needs a provisioning profile.
- **Not documented anywhere I found:** whether `security delete-generic-password` can delete another app's item silently. Forum reports say a change (`-U`) prompts but a delete may not.
- **The probe** uses a throwaway item created the way Iris does. It answers the planner's questions in order (it's waiting for Brian's OK, rule 19):
  - **(a)** Can a shell delete the item without a prompt?
  - **(b)** Can a shell recreate it under the same service and account without a prompt, both with `-A` (any app may read it) and without it?
  - **(c)** Does the creating tool's next read of a recreated item prompt?

  It also checks whether `-U` changes the original without a prompt.
- **Reading the answers:**
  - **(a) alone** is a denial of service, not a bypass. A deleted item takes the API keys with it, so it's loud, and Iris fails safe.
  - **If (c) prompts without `-A`,** a recreate is loud unless it uses `-A`. So `-A` is the case any detection has to cover.
- **If delete-and-recreate is silent:** a determined command can replace the item with chosen values, including a base URL and the attacker's own key. A still beats today, because a plain `defaults write` no longer works and the replacement wipes the real keys, which the person sees. But it doesn't meet the property. I'd then propose A now plus a detection step, with B as the follow-up:
  - **Detection:** Iris remembers the item's `kSecAttrCreationDate` inside the item. A recreated item gets a new creation date, so a mismatch means it was replaced, and Iris fails safe with a notice.
  - **What it costs an attacker, stated plainly (planner):**
    - It stops a replacement that doesn't know about the check, such as an injected model writing `security add-generic-password -A` with chosen values.
    - It does **not** stop a determined shell. That shell can create the item, read the new creation date from its attributes without a prompt, and update the data to match. That's its own `-A` item, so no prompt there either.
    - So it raises the bar against an injected model, not against a determined attacker. The note and the docs say exactly that, and it isn't a guarantee. Only B meets the property against a determined shell.

### Probe results (2026-10-19, under the GUI lease, Brian answering every prompt)

This used a throwaway item (`com.iris.probe-678`) created with `SecItemAdd` and no access object, exactly as KeychainManager creates `com.iris.secrets`. Iris's own item was never touched. The probe item was deleted afterwards and verified gone.

| Step | Result |
| --- | --- |
| A shell reads the item's attributes, creation date included (`security find-generic-password`, no `-w`) | Silent |
| A shell changes the data (`security add-generic-password -U`) | **Silent**, exit 0; the data was replaced |
| The creating tool's next read, after that change | **Prompt** (denied) |
| **(a)** A shell deletes the item (`security delete-generic-password`) | **Silent**, exit 0 |
| **(b)** A shell recreates it, without `-A` and with `-A` | **Silent**, exit 0, both |
| **(c)** The creating tool reads the recreated item, without `-A` and with `-A` | **Prompt**, both (denied) |

Probe 1 raised three prompts, one per read after a shell change, and all three were denied. Brian confirmed he saw exactly three.

**Reading:**
- **A replaced item is loud at Iris's next read,** whether it was overwritten or recreated, and whatever the access list says. `-A` doesn't silence it, which points to the item's partition list. The `security` tool's items get its own partition, and changing that list needs the keychain password.
  - On a dev build, where prompts are routine (#578), an Allow given out of habit accepts the planted data. The creation-date check is for that case.
- **A delete alone is silent.** Paired with a marker kept outside the item, that gives the known limit below.

### Probe 2 (2026-10-19, under the GUI lease): can Iris detect a replaced item without showing UI?

The planner's design read the item with `LAContext.interactionNotAllowed = true` passed as `kSecUseAuthenticationContext`, expecting `errSecInteractionNotAllowed` from a replaced item. The same throwaway item, created by a probe tool (X):

| Case | Result |
| --- | --- |
| **1** X's no-UI read of its own untouched item | `0`, silent |
| **2a** recreated by `security` without `-A`, then X's no-UI read | **A SecurityAgent dialog appeared anyway.** The read neither returned nor failed fast, and hung until the probe's 30 s timeout killed it. Brian denied the dialog afterwards. |
| **2b** recreated by `security` with `-A`, then X's no-UI read | **A dialog appeared again.** Brian chose Always Allow, and the read returned `0` with the planted value. The probe item, and that grant with it, was deleted afterwards. |

Cases 3 (`-U`) and 4 (dev-build X/Y) weren't run: the probe stopped at the first unexpected prompt, as ruled.

**Conclusion:** on the file-based keychain, `interactionNotAllowed` doesn't suppress the access-list and partition-list prompt; it applies to an item's own access-control object. The two APIs that would suppress it are deprecated, and the zero-warnings rule forbids them:
- `kSecUseAuthenticationUISkip`;
- `SecKeychainSetUserInteractionAllowed(false)`.

So there's no silent tamper read. **The prompt itself is the detector** (planner's ruling): a Deny leaves the item unreadable, the tamper table applies, and Iris never writes over the item. The Re-trust button is dropped, since nothing raises a false flag for it to answer.

### Option B: the data protection keychain

`security` can't reach it at all, which meets the property outright. The costs:
- **Signing:** it needs a provisioning profile authorising `keychain-access-groups` in the release signing (TN3137).
- **Dev builds:** the bare `swift run` binary can't use it (no bundle, no profile), so dev builds would keep a file-based fallback.
- **Migration:** every secret, the API keys included, would move.

It's a bigger change than #678 is asking for. It's the right follow-up if the probe shows a silent replace.

### Option C, origin binding for the built-in keys: not chosen

It covers base URLs only, never budgets or limits, and under A a base URL lives in the same store as the key it would leak.

### Option D, re-confirming a changed value: not chosen

It needs a trusted record of the last confirmed value, which is this same storage problem.

## The code shape (after the ruling)

- **`GuardedSettings`:** a registry of `(key, kind, safe default)`, read from and written to the secrets dict through one `KeychainManager` (injectable, so each test has its own in-memory store).
- **`ConfigManager`'s guarded properties** read from it at init, and write to it in `didSet`. They no longer touch `store`.
- **No live defaults reads:** every live `store` read of a guarded key goes through the registry, including `JobLimitSetting.configKey`'s readers.
- **`AppDefaultsImport`** may re-copy the legacy `iris` domain into defaults. That's harmless, because defaults are never read for a guarded key.
- **Tests, one per property, each mutation-checked:**
  - a Settings write applies;
  - a defaults write of each guarded key (straight to the suite) doesn't, and posts its notice once;
  - migration copies only into an existing unmarked item, then deletes the defaults keys;
  - a missing item gives the safe defaults and ignores defaults values;
  - the one-time "not carried over" notice names exactly the keys that were in defaults;
  - the seeder carries the guarded values with the dict.

## Known limits (whichever option Brian picks)

- **What the probe found, verbatim:**
  - a shell deletes Iris's item with no prompt;
  - a shell recreates it, with or without `-A`, with no prompt;
  - a shell overwrites its data with `security add-generic-password -U` with no prompt;
  - Iris's next read of a replaced item prompts, with or without `-A`.
- **Habituation:** on dev builds, prompts are routine (#578), so an Allow given out of habit accepts planted data, with no bounds beyond the type checks. A release build never asks for its own item after the first Always Allow, so a prompt there means something else changed the item: click Deny. #681 closes this.
- **First-launch trust and a silent delete:** wherever first-launch trust applies, the marker lives outside the item. Deleting the item and the marker and then planting defaults replays it. **That's loud with keys** (the API keys vanish with the item) **and silent without** (an install with no saved keys, such as Gemini over ADC).
- **Never below built-in, but a stricter choice can be reset (no-key installs)** (the planner's design, pending Brian). An old value carries over only if it's at least as strict as the built-in one, and Vibecop carries over either way. So planted defaults can never loosen past built-in. But on a no-key install, a choice stricter than built-in can be reset to built-in by a silent delete plus a plant: for example sandbox on, or lower budgets. Only #681 closes that.
- **The approval dialog's warning is a hint, not a gate.** The dialog warns when a command's text names Iris's keychain service (`com.iris.secrets*`) or its defaults domain (`com.bnaylor.iris*`). It's a string match on the command text, so a command that builds those names at run time, or reaches them indirectly, gets no warning. It helps the person notice; it doesn't stop anything.
- **The real fix** is the data protection keychain, filed as #681.

