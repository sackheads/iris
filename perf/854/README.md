Evidence harness for #854 (a real model's compliance with a planted request). Not part of any PR.
`rules.py` is the classification rule, fixed before any data; `gen854.py` builds scenarios and inert mounts
under the temp root at run time; `run854.py` runs them and prints Wilson 95% intervals. Needs `iris` from this
checkout (`--bench --real --grant-write` under the temp root is #865) and real-provider credentials.
