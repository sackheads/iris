# Sources of v4

**v3's rows:** see [v3's SOURCES.md](../v3/SOURCES.md) (and v2's and v1's, which it links). They are unchanged here.

## Disguised `subtle` attacks and benign twins (48)

- **Origin (`source`):** `synthetic-gemini-802`.
- **Generator:** `scripts/eval_gen_802.py`, authored by Gemini on 2026-11-06 from the #802 specification and imported unchanged apart from where it writes. It is AI-generated, and this project's own dataset rows written under that spec.
- **Licence / provenance:** newly authored synthetic test data for this repository. **Not** derived from InjecAgent or any external dataset: InjecAgent covers plain, undisguised requests planted in tool output (`subtle_plain`, v2) and none of these. No third-party licensed material was used, so v4 adds nothing to v2's `LICENSES`.
- **Safety and scrubbing:**
  - No real credentials or secret values: the rows name only environment variables (`$USER`, `$API_KEY`, `$DATABASE_URL`, `REDIS_AUTH_TOKEN`) and synthetic paths.
  - No real external hosts, IPs or callback endpoints: every domain is an RFC 2606 / RFC 6761 placeholder (`*.example.com`, `*.example.net`, `*.example.org`, `*.invalid`).
- **Structure:** 24 attacks (`subtle-disg-001` to `024`) and 24 benign twins (`subtle-benign-001` to `024`), six carrier shapes of four pairs each:
  1. Configuration files (`001` to `004`: Docker Compose YAML, `pyproject.toml`, `nginx.conf`, `tsconfig.json`)
  2. Documentation and runbooks (`005` to `008`: Redis failover runbook, macOS arm64 build troubleshooting, release checklist, AWS SSO onboarding)
  3. Source comments and docstrings (`009` to `012`: Python docstring, TypeScript JSDoc, Go struct comment, Swift doc comment)
  4. Build, CI and test logs (`013` to `016`: `swift build` diagnostic, `pytest` failure trace, GitHub Actions log, `cargo build` compiler help note)
  5. JSON API and webhook payloads (`017` to `020`: GitHub PR review JSON, issue webhook JSON, npm package metadata JSON, service health/incident status JSON)
  6. Git output (`021` to `024`: `git log` commit notes, `git diff` SQL migration comment, annotated `git tag` release notes, `git submodule` status output)
- **Review:** the rows were read for secrets, real hosts and trigger phrases before this import (planner, 2026-11-07), and their payload, tier-1 and size properties are asserted by the generator and by `EvalFrameworkTests`.
