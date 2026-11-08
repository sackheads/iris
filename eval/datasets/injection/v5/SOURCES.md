# Sources of v5

**v4's rows:** see [v4's SOURCES.md](../v4/SOURCES.md) (and the earlier versions it links). They are unchanged here.

## 24 new benign config-shaped rows

- **Origin (`source`):** `synthetic-952`.
- **Generator:** `scripts/eval_build_v5.py` — the rows are authored directly in that script (no external generator model), for #952 Task 5's markers-kept-vs-stripped eval.
- **Licence / provenance:** newly authored synthetic test fixtures for this repository. Not derived from any external dataset or real deployment config. No third-party licensed material was used, so v5 adds nothing to the earlier versions' `LICENSES`.
- **Safety and scrubbing:**
  - No real credentials: passwords are the placeholder `devpassword` (matching v4's `config-005`), API keys are environment-variable references (`os.environ/OPENAI_API_KEY`), and no row contains a real secret value.
  - No real hosts or endpoints: image registries, domains and bucket names are fictitious placeholders (`registry.example.org`, `widgets.example.com`, `acme-corp`, `s3://acme-raw-events`) in the style of v4's `ledger-api`/`example.net` placeholders.
  - **No attack content whatsoever** (#802's standing rule): no row contains an instruction, an imperative directed at a reader, a trigger phrase, or anything attack-adjacent. Every `system:`/`user:`/`model:`/`---` in these rows is ordinary config/YAML syntax (a container's run-as user, a Kubernetes multi-document separator, an LLM provider's model id, a chat message's role field) with no payload behind it.
- **Structure:** 24 benign rows, four carrier shapes of 6-8 each:
  1. **`compose`** (`compose-001` to `compose-008`): Docker Compose service definitions.
  2. **`k8s_yaml`** (`k8s-001` to `k8s-006`): multi-document Kubernetes manifests.
  3. **`llm_config`** (`llm_config-001` to `llm_config-006`): LLM client/provider configuration files.
  4. **`ansible`** (`ansible-001` to `ansible-004`): Ansible playbooks.
- **Review:** read for secrets, real hosts, trigger phrases and attack-adjacent wording before this import; `scripts/eval_build_v5.py` asserts exactly 24 new rows, no duplicate ids across v1-v5, and that `attacks.jsonl` is unchanged from v4.
