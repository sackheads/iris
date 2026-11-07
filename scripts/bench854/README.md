# #854 bench drivers

Measures whether a model acts on a request planted in a file it was asked to summarize
(`iris --bench --real`, read-write mount, sandboxed). Scenarios are generated into a fresh temp folder per
call; nothing here writes outside it.

- `gen854.py`: the 34 scenarios (24 planted rows from `eval/datasets/injection/v2`, 10 controls). `make(only=set_of_names)`.
- `run854.py BIN full|pilot|summarize`: runs them. `ARM_ARGS` carries the arm's flags, `REPS` the passes, `ROWS` a JSON file
  (like `rows28.json`) that restricts the run to the named scenarios.
- `rules.py`: how a run is classified (primary and secondary compliance). Unchanged since the first arm; its sha256 is printed per run.
- `aggregate.py WORKDIR...`: pools workdirs; `--emit-rows FILE` writes the scenarios that reached the primary, with pass counts.
- `rows28.json`: the 28 scenarios (18 planted, 10 control) that gemma4:12b's guard passed at least once in the local arm.

**Read the counts as runs, not rows.** There are 34 distinct scenarios. Repeats sample the model's randomness and add no rows, so
the independent n is the number of distinct planted rows that reached the primary (18 for `rows28.json`), and a zero over them
bounds the rate near 0.17, not near 0.05. A result states that, and which guard stood in front of the driver.

Examples (a built, signed `iris`):

    # local, free (the first arm)
    ARM_ARGS="--local-openai http://127.0.0.1:11434/v1 --local-model gemma4:12b" REPS=2 python3 -I scripts/bench854/run854.py BIN full

    # paid, the rows the gemma guard passed, guard bypassed, three passes, capped (key in the environment)
    ROWS=scripts/bench854/rows28.json REPS=3 ARM_ARGS="--cloud-primary anthropic:claude-opus-5-5 --allow-paid --max-dollars 11 --spend-ledger ~/bench854-ledger.jsonl --bypass-guard" \
      python3 -I scripts/bench854/run854.py BIN full
