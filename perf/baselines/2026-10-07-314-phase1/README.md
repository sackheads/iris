# #314 Phase 1 measurement: thinking replay on vs off (2026-10-07)

Spec §2.3 (self-test) and §2.4 (arm comparison) of `docs/specs/2026-10-06-anthropic-thinking-replay.md`. Run on
Vertex (`gke-claude-dev`) with the owner's approval, by `work`.

## Headline

**On this workload, Phase 1 replay (B) costs more per task and does not finish in fewer rounds.**

| reps 2-5, paired (B − A) / A per rep | median | range |
|---|---|---|
| Opus 5.5, whole suite (5 scenarios) | **+18.1%** | +9.3% … +27.3% |
| Opus 5.5, `goal-tool-loop` | **+23.7%** | +14.2% … +29.0% |
| Fable 5.1, whole suite except `tool-heavy` (see below) | +2.5% | −26.6% … +80.8% (noisy, `global` endpoint) |
| Fable 5.1, `goal-tool-loop` | **+6.3%** | +2.0% … +20.3% |

- **Rounds to completion are unchanged.** `goal-tool-loop` took 17 rounds in every run of both arms on both models
  (one B run on Opus took 18). Output tokens are unchanged within noise.
- **Where the extra cost comes from:** cache writes. B echoes each earlier reply's thinking block, and that new
  prefix is written to cache once, at 1.25×, before later rounds read it cheaply. On Opus's `goal-tool-loop`, cache
  writes went from about 6.5K tokens (A, reps 2-5: 6387 / 9113 / 5480 / 5239) to about 11.7K (B: 12542 / 13218 /
  11170 / 9947), with reads flat.
- **Task success: 20/20** (`goal-tool-loop`, all arms and models). The tasks are easy, so this suite can't show the
  benefit replay is *for*: keeping the model's reasoning across tool rounds on hard problems. Any case for Phase 2 has
  to come from a quality eval, not from cost or round counts.
- **Correctness:** across every model call of all 20 runs, **0** responses carried a non-empty
  `input_transformations`. Replay never sent a block the API rejected or dropped.
- **Thinking is sparse at Iris's default effort**, which bounds how much replay can carry. In `goal-tool-loop`, B
  echoed 6.4 blocks per run on Opus (in 5.4 of 17 requests) and 2.0 on Fable (2 of 17).
  `echoed-thinking-blocks.json` lists the count for every request.

## Setup

- **A** = main at `8250a35` (#392: blocks stored, never replayed). **B** = main at `1bc2d8b` (#393: Phase 1 replay
  on). Nothing else lies between the two commits.
- **One identical patch on both arms** (`measurement-seed-override.patch`): `IRIS_PERF_SEED_JSON` overrides keys in
  the perf run's *volatile* settings copy, so a run can target Anthropic on Vertex without writing the real
  preferences domain. Not merged into the source. Records are flagged `gitDirty` because of it and the new suite.
- **Suite** `perf/suites/314-phase1.json` (committed here): the four `caching` scenarios plus a new
  `perf/prompts/314/goal-tool-loop.json`. That scenario has 3 turns, each asking for 4-5 *dependent* shell steps one
  at a time, so every step is its own model round with something to carry (17 rounds, 14 `run_command`s). Real lane,
  rung 4, `run_command` sandboxed, iris release builds, streaming on, Iris's default effort (none sent).
- **Models and endpoints:** Opus 5.5 on Vertex **`us`**; Fable 5.1 on **`global`**, because on `us` it returns 403
  "requires data sharing to be enabled for publisher 'anthropic'" (a project setting not changed for this). Base prices
  `IRIS_PERF_BASE_PRICE_PER_MTOK` = 4 (Opus) and 10 (Fable); weights are #381's (reads 0.05 Opus, 0.025 Fable;
  writes 1.25 / 2.0; output 5).
- **Order:** 5 reps × 2 arms × 2 models, one suite repetition per invocation. Arm order alternates by rep (A first on
  odd reps), and models interleave, so two runs of the same model are always separated by a run of the other: about
  2 minutes, which is less than the 5-minute TTL, but at least the other model's traffic sits in between.
- **Confounds, and how they're handled:**
  - #321's per-run temp home is fixed on main (the scratch path is the fixed `$TMPDIR/iris-perf`), so it is identical
    for every run of both arms.
  - **Rep 1 was the night's first traffic**, and A ran first, so A r1 paid the cold-cache writes on both models (Opus
    A r1 $1.19 against about $0.37 for the other A reps). The headline therefore uses reps 2-5. The full tables below
    include rep 1.
  - `pinned-briefing` runs in the pinned conversation at a 1-hour TTL, so its prefix carries across runs in both arms.
    Excluding it changes Opus's suite figure from +18.1% to +19.4%.
  - **`global` caching is noisy.** One smoke run on `global` missed the cache on 5 of 16 rounds mid-turn ($0.54) where
    the same scenario on `us` read every round ($0.20). A direct back-to-back 10-request test on `global` hit 9/9, so
    the cause isn't simple per-request routing, and it isn't established. Fable's cost figures carry this noise in both
    arms.

## Self-test (§2.3): binding check under `prefix_mismatch_behavior: "error"`, 3× per model

Mint a thinking block, replay it on an unchanged prefix, then replay it after editing the first user message.

| model | honest replay | edited replay |
|---|---|---|
| claude-opus-5-5 | 200, `[]` (3/3) | 400 "…Invalid `signature` in `thinking` block. The block is bound to a different conversation…", diagnosis header `pattern=first_message_rewritten` (3/3) |
| claude-fable-5-1 | 200, `[]` (3/3) | same 400 and header (3/3) |
| claude-sonnet-5-5 | 200, `[]` (3/3) | same 400 and header (3/3) |

**This project is not enforced**: with the field unset, an edited replay is accepted, and with the header alone it is
recorded as `thinking_mismatch_allowed` (details on #384). So the check runs on all three models; it just isn't
enforced for this account.

## An unexplained arm difference: Fable 5.1 batching in `tool-heavy`

On Fable, `tool-heavy`'s turn 2 ("run these 12 commands … one at a time") took **6 rounds in all 5 B runs and 17 in all
5 A runs**. B's first reply issued all 12 calls in parallel (about 1,000-1,200 output tokens). A's issued one call per
round (about 260-320 output tokens). That split drives Fable's whole-suite −9% (reps 2-5) and isn't a replay effect:

- the first round of a turn echoes nothing, and the two arms' requests for that round are identical apart from the
  model's own earlier greeting and a fact UUID (same system, tools, `max_tokens`, `cache_control` positions);
- the dumped request is exactly the one sent (`requestToSend` feeds both the dump and the client);
- replaying those exact bodies to Fable gives the same mixed behaviour for both arms. Non-streamed: A's body batched
  3/5, B's 1/5. Streamed: A's 1/6, B's 1/6.

So the 5/5 versus 0/5 split isn't reproducible from what each arm sent, and its cause isn't established. Opus never
batched in either arm. The Fable rows are shown both with and without `tool-heavy`.

## Full tables (all reps)

`analyze.py` recomputes these from the records here and the request dumps, which aren't committed (43 MB, full of
signatures). The echo counts in `echoed-thinking-blocks.json` come from those dumps.

### claude-opus-5-5  (reps: A=5, B=5)

| scenario | arm | $/task (mean ± sd [min–max]) | weighted | input (uncached) | cache read | cache write | output | rounds | tool calls | echoed blocks / requests with any | success |
|---|---|---|---|---|---|---|---|---|---|---|---|
| six-turns | A | $0.0845 ± 0.0905 [0.0399–0.2462] | 21,113 ± 22,613 [9,976–61,548] | 26 ± 0 [26–26] | 88,870 ± 18,303 [56,132–97,443] | 10,401 ± 18,317 [1,778–43,164] | 728 ± 141 [571–952] | 7.0 [7–7] | 1.0 | 0.0 / 0.0 of 7.0 | — |
| six-turns | B | $0.0679 ± 0.0318 [0.0467–0.1237] | 16,964 ± 7,949 [11,675–30,931] | 26 ± 1 [26–28] | 97,237 ± 9,836 [83,491–111,306] | 5,742 ± 6,537 [2,074–17,392] | 980 ± 105 [840–1,131] | 7.2 [7–8] | 1.4 | 1.0 / 1.0 of 7.2 | — |
| every-turn-facts | A | $0.0485 ± 0.0036 [0.0448–0.0543] | 12,129 ± 909 [11,202–13,583] | 26 ± 0 [26–26] | 97,413 ± 487 [96,841–97,973] | 2,600 ± 427 [2,034–3,053] | 796 ± 177 [617–1,094] | 7.0 [7–7] | 1.0 | 0.0 / 0.0 of 7.0 | — |
| every-turn-facts | B | $0.0533 ± 0.0079 [0.0449–0.0659] | 13,336 ± 1,966 [11,235–16,465] | 26 ± 1 [26–28] | 99,928 ± 6,214 [96,545–111,009] | 3,155 ± 841 [2,230–4,429] | 874 ± 210 [599–1,082] | 7.2 [7–8] | 1.2 | 0.4 / 0.4 of 7.2 | — |
| tool-heavy | A | $0.1504 ± 0.0389 [0.1219–0.2186] | 37,599 ± 9,719 [30,466–54,652] | 44 ± 0 [44–44] | 243,962 ± 7,156 [231,356–249,040] | 13,505 ± 7,274 [8,300–26,320] | 1,695 ± 218 [1,485–2,028] | 17.0 [17–17] | 12.0 | 0.0 / 0.0 of 17.0 | — |
| tool-heavy | B | $0.1534 ± 0.0239 [0.1390–0.1955] | 38,360 ± 5,965 [34,742–48,863] | 44 ± 0 [44–44] | 244,176 ± 4,980 [235,330–247,076] | 14,264 ± 4,927 [11,601–23,062] | 1,655 ± 188 [1,403–1,933] | 17.0 [17–17] | 12.0 | 12.0 / 12.0 of 17.0 | — |
| pinned-briefing | A | $0.1285 ± 0.2081 [0.0340–0.5008] | 32,117 ± 52,036 [8,512–125,198] | 20 ± 0 [20–20] | 62,141 ± 26,317 [15,064–73,988] | 13,431 ± 26,338 [1,573–60,545] | 426 ± 156 [289–667] | 5.0 [5–5] | 1.0 | 0.0 / 0.0 of 5.0 | — |
| pinned-briefing | B | $0.0393 ± 0.0041 [0.0336–0.0434] | 9,834 ± 1,034 [8,396–10,859] | 20 ± 0 [20–20] | 73,946 ± 53 [73,884–73,992] | 1,646 ± 52 [1,576–1,717] | 565 ± 188 [305–742] | 5.0 [5–5] | 1.0 | 0.0 / 0.0 of 5.0 | — |
| goal-tool-loop | A | $0.1275 ± 0.0306 [0.1069–0.1806] | 31,869 ± 7,645 [26,727–45,143] | 40 ± 0 [40–40] | 243,890 ± 6,498 [232,841–248,025] | 9,342 ± 6,420 [5,239–20,493] | 1,591 ± 82 [1,546–1,737] | 17.0 [17–17] | 14.2 | 0.0 / 0.0 of 17.0 | 5/5 |
| goal-tool-loop | B | $0.1602 ± 0.0460 [0.1318–0.2415] | 40,041 ± 11,509 [32,940–60,369] | 40 ± 1 [40–42] | 241,453 ± 14,291 [219,405–258,750] | 16,143 ± 9,972 [9,947–33,839] | 1,550 ± 152 [1,412–1,778] | 17.2 [17–18] | 14.6 | 6.4 / 5.4 of 17.2 | 5/5 |
| TOTAL | A | $0.5393 ± 0.3657 [0.3576–1.1931] | 134,828 ± 91,437 [89,411–298,278] | 156 ± 0 [156–156] | 736,275 ± 57,676 [633,193–765,341] | 49,280 ± 57,961 [19,848–152,883] | 5,237 ± 476 [4,876–5,990] | 53.0 [53–53] | 29.2 | 0.0 / 0.0 of 53.0 | 5/5 |
| TOTAL | B | $0.4741 ± 0.0752 [0.4075–0.5914] | 118,535 ± 18,808 [101,869–147,862] | 157 ± 2 [156–160] | 756,740 ± 19,776 [736,966–786,500] | 40,950 ± 15,488 [27,854–65,184] | 5,624 ± 62 [5,522–5,687] | 53.6 [53–55] | 30.2 | 19.8 / 18.8 of 53.6 | 5/5 |

- paired (B − A) / A, TOTAL, per rep: -50.4%, +17.9%, +27.3%, +18.3%, +9.3%; mean +4.5%, median +17.9%

- paired (B − A) / A, goal-tool-loop, per rep: +33.7%, +29.0%, +14.2%, +24.2%, +23.2%; mean +24.9%, median +24.2%

### claude-fable-5-1  (reps: A=5, B=5)

| scenario | arm | $/task (mean ± sd [min–max]) | weighted | input (uncached) | cache read | cache write | output | rounds | tool calls | echoed blocks / requests with any | success |
|---|---|---|---|---|---|---|---|---|---|---|---|
| six-turns | A | $0.1607 ± 0.2221 [0.0528–0.5577] | 16,071 ± 22,210 [5,276–55,772] | 26 ± 0 [26–26] | 89,159 ± 18,274 [56,479–97,781] | 9,626 ± 18,292 [1,040–42,339] | 357 ± 115 [253–529] | 7.0 [7–7] | 1.0 | 0.0 / 0.0 of 7.0 | — |
| six-turns | B | $0.0707 ± 0.0046 [0.0628–0.0745] | 7,066 ± 460 [6,282–7,452] | 26 ± 0 [26–26] | 97,058 ± 297 [96,675–97,478] | 1,885 ± 322 [1,343–2,140] | 451 ± 36 [416–504] | 7.0 [7–7] | 1.0 | 0.6 / 0.6 of 7.0 | — |
| every-turn-facts | A | $0.1082 ± 0.0724 [0.0713–0.2377] | 10,819 ± 7,244 [7,131–23,769] | 26 ± 0 [26–26] | 94,445 ± 5,962 [83,784–97,359] | 5,401 ± 5,954 [2,473–16,047] | 336 ± 21 [316–365] | 7.0 [7–7] | 1.0 | 0.0 / 0.0 of 7.0 | — |
| every-turn-facts | B | $0.0712 ± 0.0052 [0.0665–0.0775] | 7,124 ± 524 [6,645–7,754] | 26 ± 0 [26–26] | 97,530 ± 463 [96,976–97,915] | 2,326 ± 457 [1,949–2,871] | 351 ± 11 [340–367] | 7.0 [7–7] | 1.0 | 0.0 / 0.0 of 7.0 | — |
| tool-heavy | A | $0.2983 ± 0.0642 [0.2323–0.4054] | 29,829 ± 6,424 [23,229–40,537] | 44 ± 0 [44–44] | 245,383 ± 5,937 [235,470–251,515] | 12,743 ± 5,591 [6,806–22,001] | 1,544 ± 97 [1,421–1,678] | 17.0 [17–17] | 12.0 | 0.0 / 0.0 of 17.0 | — |
| tool-heavy | B | $0.2067 ± 0.0239 [0.1749–0.2407] | 20,672 ± 2,390 [17,492–24,073] | 22 ± 0 [22–22] | 85,056 ± 1,723 [82,684–87,539] | 8,540 ± 1,784 [5,997–11,023] | 1,570 ± 96 [1,412–1,648] | 6.0 [6–6] | 12.0 | 1.0 / 1.0 of 6.0 | — |
| pinned-briefing | A | $0.1756 ± 0.2609 [0.0562–0.6424] | 17,562 ± 26,092 [5,617–64,236] | 20 ± 0 [20–20] | 68,271 ± 13,241 [44,586–74,276] | 7,305 ± 13,223 [1,290–30,958] | 245 ± 13 [232–261] | 5.0 [5–5] | 1.0 | 0.0 / 0.0 of 5.0 | — |
| pinned-briefing | B | $0.1169 ± 0.1341 [0.0527–0.3567] | 11,689 ± 13,414 [5,268–35,672] | 20 ± 0 [20–20] | 71,352 ± 6,799 [59,191–74,506] | 4,261 ± 6,796 [1,080–16,416] | 273 ± 47 [244–355] | 5.0 [5–5] | 1.0 | 0.2 / 0.2 of 5.0 | — |
| goal-tool-loop | A | $0.2837 ± 0.1519 [0.1951–0.5537] | 28,374 ± 15,194 [19,510–55,365] | 40 ± 0 [40–40] | 242,044 ± 12,662 [219,511–249,008] | 11,803 ± 12,549 [4,832–34,126] | 1,506 ± 63 [1,436–1,563] | 17.0 [17–17] | 14.0 | 0.0 / 0.0 of 17.0 | 5/5 |
| goal-tool-loop | B | $0.2318 ± 0.0202 [0.2148–0.2566] | 23,179 ± 2,024 [21,476–25,659] | 40 ± 0 [40–40] | 246,048 ± 1,663 [243,934–247,593] | 7,727 ± 1,536 [6,401–9,547] | 1,466 ± 31 [1,441–1,514] | 17.0 [17–17] | 14.0 | 2.0 / 2.0 of 17.0 | 5/5 |
| TOTAL | A | $1.0266 ± 0.6766 [0.6367–2.2304] | 102,655 ± 67,664 [63,672–223,041] | 156 ± 0 [156–156] | 739,303 ± 48,394 [653,405–768,545] | 46,878 ± 47,891 [18,102–131,897] | 3,988 ± 176 [3,692–4,119] | 53.0 [53–53] | 29.0 | 0.0 / 0.0 of 53.0 | 5/5 |
| TOTAL | B | $0.6973 ± 0.1558 [0.6097–0.9736] | 69,731 ± 15,578 [60,969–97,356] | 134 ± 0 [134–134] | 597,044 ± 7,865 [583,097–601,697] | 24,738 ± 8,230 [20,252–39,298] | 4,110 ± 156 [3,864–4,242] | 42.0 [42–42] | 29.0 | 3.8 / 3.8 of 42.0 | 5/5 |

- paired (B − A) / A, TOTAL, per rep: -70.3%, +36.9%, -14.1%, -4.2%, -25.5%; mean -15.4%, median -14.1%

- paired (B − A) / A, goal-tool-loop, per rep: -60.2%, +20.3%, +2.5%, +2.0%, +10.1%; mean -5.1%, median +2.5%

- model calls with non-empty input_transformations, all runs: 0

## Robust views (medians; reps 1-5 and 2-5; paired B − A per rep)

```

## claude-opus-5-5
all five scenarios       reps 1-5: A median $0.3766 [0.3576-1.1931]  B median $0.4440 [0.4075-0.5914]  paired B-A: median +17.9% [-50.4%..+27.3%]
all five scenarios       reps 2-5: A median $0.3747 [0.3576-0.3965]  B median $0.4336 [0.4075-0.5046]  paired B-A: median +18.1% [+9.3%..+27.3%]
goal-tool-loop only      reps 1-5: A median $0.1164 [0.1069-0.1806]  B median $0.1430 [0.1318-0.2415]  paired B-A: median +24.2% [+14.2%..+33.7%]
goal-tool-loop only      reps 2-5: A median $0.1123 [0.1069-0.1253]  B median $0.1387 [0.1318-0.1502]  paired B-A: median +23.7% [+14.2%..+29.0%]
all but tool-heavy       reps 1-5: A median $0.2449 [0.2307-0.9745]  B median $0.3051 [0.2645-0.3960]  paired B-A: median +15.9% [-59.4%..+40.9%]
all but tool-heavy       reps 2-5: A median $0.2403 [0.2307-0.2587]  B median $0.2892 [0.2645-0.3645]  paired B-A: median +20.3% [+14.7%..+40.9%]
all but pinned-briefing  reps 1-5: A median $0.3420 [0.3192-0.6923]  B median $0.4075 [0.3739-0.5493]  paired B-A: median +19.1% [-20.7%..+27.2%]
all but pinned-briefing  reps 2-5: A median $0.3402 [0.3192-0.3624]  B median $0.3948 [0.3739-0.4612]  paired B-A: median +19.4% [+10.5%..+27.2%]
  goal-tool-loop write   reps 2-5: A [6387, 9113, 5480, 5239]  B [12542, 13218, 11170, 9947]
  goal-tool-loop read    reps 2-5: A [248025, 243168, 247553, 247861]  B [258750, 240006, 242286, 246819]
  goal-tool-loop output  reps 2-5: A [1737, 1546, 1556, 1549]  B [1778, 1438, 1496, 1625]
  goal-tool-loop rounds  reps 2-5: A [17, 17, 17, 17]  B [18, 17, 17, 17]

## claude-fable-5-1
all five scenarios       reps 1-5: A median $0.7208 [0.6367-2.2304]  B median $0.6208 [0.6097-0.9736]  paired B-A: median -14.1% [-70.3%..+36.9%]
all five scenarios       reps 2-5: A median $0.7160 [0.6367-0.8336]  B median $0.6202 [0.6097-0.9736]  paired B-A: median -9.1% [-25.5%..+36.9%]
goal-tool-loop only      reps 1-5: A median $0.2133 [0.1951-0.5537]  B median $0.2206 [0.2148-0.2566]  paired B-A: median +2.5% [-60.2%..+20.3%]
goal-tool-loop only      reps 2-5: A median $0.2126 [0.1951-0.2447]  B median $0.2335 [0.2148-0.2566]  paired B-A: median +6.3% [+2.0%..+20.3%]
all but tool-heavy       reps 1-5: A median $0.4313 [0.4044-1.8250]  B median $0.4222 [0.4097-0.7640]  paired B-A: median +2.0% [-76.9%..+80.8%]
all but tool-heavy       reps 2-5: A median $0.4269 [0.4044-0.5580]  B median $0.4285 [0.4097-0.7640]  paired B-A: median +2.5% [-26.6%..+80.8%]
all but pinned-briefing  reps 1-5: A median $0.6647 [0.5759-1.5881]  B median $0.5681 [0.5519-0.6168]  paired B-A: median -14.8% [-62.3%..-4.2%]
all but pinned-briefing  reps 2-5: A median $0.6579 [0.5759-0.7750]  B median $0.5671 [0.5519-0.6168]  paired B-A: median -10.0% [-26.7%..-4.2%]
  goal-tool-loop write   reps 2-5: A [5946, 8405, 5708, 4832]  B [9547, 9238, 6537, 6401]
  goal-tool-loop read    reps 2-5: A [247747, 245588, 248366, 249008]  B [244606, 243934, 247290, 247593]
  goal-tool-loop output  reps 2-5: A [1532, 1557, 1563, 1441]  B [1514, 1480, 1445, 1449]
  goal-tool-loop rounds  reps 2-5: A [17, 17, 17, 17]  B [17, 17, 17, 17]
```

## Spend

The 20 runs cost **$13.69** at list prices (Opus $5.07, Fable $8.62). Smoke runs, the self-test and the batching
diagnostics added about $3.

## Reproduce

```sh
git worktree add /tmp/armA 8250a35 && git -C /tmp/armA apply perf/baselines/2026-10-07-314-phase1/measurement-seed-override.patch
git worktree add /tmp/armB 1bc2d8b && git -C /tmp/armB apply perf/baselines/2026-10-07-314-phase1/measurement-seed-override.patch
# copy perf/suites/314-phase1.json and perf/prompts/314/ into both, `swift build -c release` in each, then per run:
IRIS_PERF_SEED_JSON='{"PRIMARY_PROVIDER":"Anthropic","ANTHROPIC_AUTH_MODE":"Vertex AI (ADC)","ANTHROPIC_VERTEX_PROJECT":"<project>","ANTHROPIC_VERTEX_LOCATION":"us","ANTHROPIC_MODEL_MEDIUM":"claude-opus-5-5"}' \
IRIS_PERF_BASE_PRICE_PER_MTOK=4 .build/release/iris --perf run perf/suites/314-phase1.json --out <dir> --dump-requests <dumps>
python3 perf/baselines/2026-10-07-314-phase1/analyze.py <runs-root> <dumps-root>
```
