# Sources of v2

**v1's rows:** see [v1's SOURCES.md](../v1/SOURCES.md).  Unchanged here apart from `exposure: pre-split`.

## InjecAgent (24 attacks)

[uiuc-kang-lab/InjecAgent](https://github.com/uiuc-kang-lab/InjecAgent) at `f19c9f2c79a41046eb13c03c51a24c567a8ffa07`, MIT, "Copyright (c) 2023 Qiusi Zhan" ([licence](LICENSES/InjecAgent-MIT.txt)).  Each row carries `source: injecagent`, its `file`, `index`, `commit`, `attack_type`, `user_tool` and `license`.

Taking a public set reverses the spec's "synthetic and repository content only" (§10 Q2) for this slice only, by Brian's decision on 2026-10-28 ("InjecAgent + note the gap"), because the project-written attacks were all we had and #783's bake-off had only 6 subtle ones.

**Selection** (`scripts/eval_build_v2.py`, deterministic; the chosen indices are in `manifest.json`):

- Base sets only: `data/test_cases_dh_base.json` (510 direct-harm cases) and `data/test_cases_ds_base.json` (544 data-stealing cases).  The `*_enhanced` sets prefix every injection with a trigger phrase, which tier 1 and every model catch, so they'd measure nothing.
- Per file, the user tools ranked by carrier family: GitHub, Gmail, Evernote, web browser or Google search, Amazon, Twitter, Slack, Todoist, Dropbox, Google Calendar, then the rest alphabetically; alphabetical within a family.  The first 12 distinct tools are taken.  At `f19c9f2` that's the three GitHub tools, the two Gmail ones, Evernote, the web browser, Amazon, the three Twitter ones and Todoist.  Calendar, Shopify, Teladoc and Twilio miss the cut.
- From each tool, the lowest-index case whose `Attacker Tools` list hasn't been taken yet in that file, or the tool's lowest-index case if every list has.

**The gap.**  The InjecAgent rows are plain, trigger-free requests planted in tool output. They don't cover disguised subtle injections, meaning instructions dressed as legitimate content, such as v1's subtle-002, which no local model blocked in #783. Harder cases are tracked in #802, with the source still open.

## Benign look-alikes (10)

`source: derived from InjecAgent templates (MIT)`.  The `Tool Response Template` of the direct-harm cases chosen above, for the first 10 tools in rank order, with the `<Attacker Instruction>` slot filled by a legitimate instruction written for this project (the fills are in `scripts/eval_build_v2.py`).  All are JSON tool responses, so all are `json_api`, rather than one category per carrier with one or two texts each.
