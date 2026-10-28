<!-- What the change does, why, and how it was verified (test counts; a filtered run states how many tests ran). -->

## What does this change make untrue?

<!-- Invariant 9 (AGENTS.md). Search, do not compose: grep for the behaviour you changed and read
what comes back in README.md, docs/, GoalContract.oracleText, tool `description` fields, and
system prompts (SYSTEM.md, EVALUATOR.md and the skills in Sources/IrisKit/assets/, VibecopService). Name each sentence you fixed, or say
what you searched. "Nothing" is a fine answer; not looking is not. The reviewer checks this. -->

## Guard changes

<!-- Only for a change to the prompt-injection guard (InjectionGuard, CoreMLEvaluator, a tier's
prompt or threshold). Delete otherwise. -->
- [ ] A guard fix adds its case (the missed attack or the false positive it fixes) to the next eval dataset version, so the fix stays tested (docs/specs/2026-10-28-model-eval-framework.md, section 9).
