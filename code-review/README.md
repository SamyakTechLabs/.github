# AI Code Review — Reusable Workflow

A provider-agnostic GitHub Actions workflow that runs an LLM-driven code review on every pull request and posts findings as inline comments + a summary comment. Lives in this org's `.github` repo so any repo can `uses:` it.

- **Workflow:** `.github/workflows/code-review.yml`
- **Helper script:** `.github/scripts/code-review/call_api.py`
- **Sample caller:** [`code-review.example.yml`](./code-review.example.yml)

## Contents

- [What it does](#what-it-does)
- [Quick start](#quick-start)
- [Provider examples](#provider-examples)
- [Inputs reference](#inputs-reference)
- [Secrets reference](#secrets-reference)
- [Per-repo configuration & context (`.code-review.yml`)](#code-review-yml-reference)
- [How comments get posted](#how-comments-get-posted)
- [Skip & error notifications](#skip-and-error-notifications)
- [Triggers and skip conditions](#triggers-and-skip-conditions)
- [Permissions](#permissions)
- [Cost / latency notes](#cost-and-latency)
- [Troubleshooting](#troubleshooting)

<details id="what-it-does">
<summary><b>What it does</b></summary>

1. On every non-draft pull request: collects the diff of changed files (excluding lockfiles, images, markdown).
2. Sends each file's diff to the chosen LLM provider with a strict reviewer system prompt — flag concrete bugs/security/data/breaking issues only; no style.
3. Posts inline PR comments for each finding, anchored to lines that actually exist in the diff.
4. Deduplicates against prior bot comments on the same PR (updates instead of re-posting).
5. Posts a single summary comment at the end ("All good" or a one-line risk assessment).

</details>

<details id="quick-start">
<summary><b>Quick start</b></summary>

### 1. Add the caller workflow

Copy [`code-review.example.yml`](./code-review.example.yml) into your repo at `.github/workflows/code-review.yml`:

```yaml
name: Code Review

on:
    pull_request:
        types: [opened, synchronize, reopened, ready_for_review]
        branches: [master, main]

jobs:
    review:
        uses: SamyakTechLabs/.github/.github/workflows/code-review.yml@main
        with:
            provider: openai
            model: gpt-4o
        secrets:
            CODE_REVIEW_API_KEY: ${{ secrets.OPENAI_API_KEY }}
```

### 2. Set your provider API key as a repo (or org) secret

Repo settings → Secrets and variables → Actions → New repository secret. Name it whatever you like (e.g. `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `ZAI_API_KEY`) and map it to `CODE_REVIEW_API_KEY` in the `secrets:` block above.

### 3. (Optional) Tune per-repo behaviour

Add a `.code-review.yml` file at the root of your repo — see [Per-repo configuration & context (`.code-review.yml`)](#code-review-yml-reference) below.

</details>

<details id="provider-examples">
<summary><b>Provider examples</b></summary>

### OpenAI

```yaml
with:
    provider: openai
    model: gpt-4o     # or gpt-4o-mini, gpt-5, etc.
secrets:
    CODE_REVIEW_API_KEY: ${{ secrets.OPENAI_API_KEY }}
```

### Anthropic (Claude)

```yaml
with:
    provider: anthropic
    model: claude-sonnet-4-6    # or claude-opus-4-7, claude-haiku-4-5
secrets:
    CODE_REVIEW_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
```

### Z.AI (GLM)

```yaml
with:
    provider: zai
    model: glm-5.1
secrets:
    CODE_REVIEW_API_KEY: ${{ secrets.ZAI_API_KEY }}
```

### Google Gemini

```yaml
with:
    provider: gemini
    model: gemini-2.5-pro
secrets:
    CODE_REVIEW_API_KEY: ${{ secrets.GEMINI_API_KEY }}
```

### xAI Grok / DeepSeek / OpenRouter

```yaml
with: { provider: xai,        model: grok-2 }
with: { provider: deepseek,   model: deepseek-chat }
with: { provider: openrouter, model: anthropic/claude-sonnet-4-6 }
```

### Custom (Azure OpenAI, Ollama, self-hosted proxies, anything else)

Use `provider: custom` and supply `api_url` + `api_format`. `extra_headers` lets you override defaults (e.g. Azure uses `api-key:` instead of `Authorization: Bearer`).

**Azure OpenAI:**

```yaml
with:
    provider: custom
    api_url: https://my-instance.openai.azure.com/openai/deployments/gpt-4/chat/completions?api-version=2024-02-01
    api_format: openai
    model: gpt-4
    extra_headers: '{"Authorization": "", "api-key": "$CODE_REVIEW_API_KEY"}'
secrets:
    CODE_REVIEW_API_KEY: ${{ secrets.AZURE_OPENAI_KEY }}
```

**Self-hosted Ollama exposed via tunnel:**

```yaml
with:
    provider: custom
    api_url: https://ollama.mycompany.internal/v1/chat/completions
    api_format: openai
    model: llama3.1:70b
secrets:
    CODE_REVIEW_API_KEY: ${{ secrets.OLLAMA_BEARER_TOKEN }}
```

</details>

<details id="inputs-reference">
<summary><b>Inputs reference</b></summary>

| Input | Required | Default | Description |
|---|---|---|---|
| `provider` | yes | — | One of `openai`, `anthropic`, `zai`, `gemini`, `xai`, `deepseek`, `openrouter`, `custom`. |
| `model` | yes | — | Model identifier passed to the provider (e.g. `gpt-4o`, `claude-sonnet-4-6`, `glm-5.1`, `gemini-2.5-pro`). |
| `api_url` | when `provider: custom` | provider default | Full endpoint URL. Optional override for named providers. |
| `api_format` | when `provider: custom` | provider default | One of `openai`, `anthropic`, `gemini`. Determines request/response shape. |
| `extra_headers` | no | `{}` | JSON object of extra request headers. Values may contain `$CODE_REVIEW_API_KEY` (interpolated from the secret). Setting a value to `""` deletes the matching default header. |
| `timeout_minutes` | no | `10` | Job timeout. |
| `max_diff_lines` | no | `1500` | Skip files with diffs longer than this — likely generated/vendored. |
| `diff_context` | no | `30` | Lines of context around each diff hunk (`git diff -U`). Lower = fewer tokens per call. `10` typically works fine. |
| `max_files` | no | `50` | Skip the entire review (with a PR comment) when the PR touches more than this many files. Guards against runaway cost on large PRs. |
| `parallelism` | no | `4` | Number of files reviewed concurrently. Lower it if your provider rate-limits you. |

</details>

<details id="secrets-reference">
<summary><b>Secrets reference</b></summary>

| Secret | Required | Description |
|---|---|---|
| `CODE_REVIEW_API_KEY` | yes | The provider's API key. Map your provider-specific secret (e.g. `OPENAI_API_KEY`) to this canonical name in the caller's `secrets:` block. |

</details>

<details id="code-review-yml-reference">
<summary><b>Per-repo configuration &amp; context (<code>.code-review.yml</code>)</b></summary>

Drop this file at the **root of your repo** (not in `.github/`) to customise review behaviour for that repo. Every key is optional — omit anything you don't need.

```yaml
# .code-review.yml

# Free-form context appended to every prompt. Useful for warning the
# reviewer about repo-specific conventions, sensitive areas, or things
# it should weigh more heavily.
context: |
    This is a PCI-DSS scoped service. Pay extra attention to anything
    touching card data, logging of request bodies, or auth bypasses.
    All HTTP handlers must validate the X-Tenant-Id header explicitly.

# Patterns the reviewer should treat as accepted in this codebase.
# Used to suppress false positives that come from following established
# conventions that look unusual.
accepted_patterns:
    - "Returning null from service methods instead of throwing — caller checks."
    - "Direct SQL via the `q` helper — it parameterises internally."
    - "`logger.info(JSON.stringify(req.body))` in dev-only branches."

# Severity floor. Findings below this level are dropped before posting.
# Values: critical | warning
# Default: warning  (i.e. info/style level findings are always dropped,
# which is fine because the reviewer is instructed not to produce them).
min_severity: critical

# Glob-style patterns for files to exclude from review. Combined with
# the built-in ignore list (package-lock.json, yarn.lock, pnpm-lock.yaml,
# *.png, *.jpg, *.jpeg, *.svg, *.gif, *.ico, *.md).
#
# Patterns are converted to regex internally: `**/` is stripped, `.` is
# escaped, `*` becomes `.*`. Keep them simple — basename or extension
# suffixes work best.
ignore:
    - "**/*.snap"
    - "**/*.lock"
    - "**/generated/**"
    - "**/migrations/*.sql"
    - "dist/**"
    - "build/**"
```

### Field details

#### `context` (string)

Appended verbatim to the per-file prompt. The reviewer reads it before evaluating the diff. Use it to:

- Flag domains where the LLM should be stricter (auth, billing, multi-tenant boundaries).
- Spell out invariants that aren't obvious from the code (e.g. "every mutation must emit an audit event").
- Note ambient constraints (compliance regime, performance budget, expected concurrency).

Keep it short — every token costs review latency and money. A few sentences is plenty.

#### `accepted_patterns` (list of strings)

Each entry describes a pattern the reviewer should NOT flag. The reviewer is already told to ignore "patterns already established in the file" — this list reinforces that for cross-file conventions it can't see in a single diff. Use it after you see the bot flag a false positive twice.

#### `min_severity` (`critical` | `warning`)

Default `warning`. Set to `critical` to only surface findings the reviewer marks `critical` — useful in noisy repos while you tune `accepted_patterns`, or in repos where the bot's role is "block on showstoppers only."

The reviewer is instructed to use only `critical` and `warning`; there is no `info` severity.

#### `ignore` (list of glob patterns)

Adds to the built-in exclude list. Built-ins (always applied):

- Lockfiles: `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`
- Images: `*.png`, `*.jpg`, `*.jpeg`, `*.svg`, `*.gif`, `*.ico`
- Docs: `*.md`

Pattern translation is naive: `**/` is dropped, `.` is escaped, `*` becomes `.*`. The result is matched against each file path via `grep -E`. Test by running:

```bash
echo "your/changed/file.path" | grep -E '(pattern1|pattern2)'
```

</details>

<details id="how-comments-get-posted">
<summary><b>How comments get posted</b></summary>

- **Inline comments** are posted on lines that appear as `+` in the diff (RIGHT side of the PR). The workflow validates every line number from the LLM against the actual diff and skips any that don't match — protects against the LLM hallucinating line numbers.
- **Deduplication:** before posting, the workflow fetches every comment by `github-actions[bot]` on the PR. A new finding on the same `path`+`line` with an identical body is skipped silently; a new finding with a different body updates the existing comment. This makes repeated `synchronize` events idempotent.
- **Summary comment:** posted once per workflow run. It is *not* deduplicated — every run appends a fresh summary, so reviewers can scan the PR timeline to see the bot's history.
- **Severity filter:** findings below `min_severity` are stripped *before* the comment-post step, so they never appear.

</details>

<details id="skip-and-error-notifications">
<summary><b>Skip &amp; error notifications</b></summary>

Whenever a review is skipped or fails, the workflow posts a PR comment so the author isn't left guessing. Four scenarios:

| Scenario | Cause | Comment posted |
|---|---|---|
| **No reviewable files** | Every changed file matched the ignore list (lockfiles, images, docs, or your `.code-review.yml` `ignore` patterns). | ℹ️ "No reviewable files in this PR." |
| **Over `max_files` cap** | The PR touches more files than the configured `max_files` input. | ⚠️ "PR touches N files (max_files=M). Split into smaller PRs or raise the cap." |
| **All per-file calls failed** | Every API call errored out (provider outage, bad key, malformed `extra_headers`, model unavailable, etc.). | ❌ "Every per-file review call failed for this PR." |
| **Workflow step errored** | Anything unexpected — exception, timeout, OOM. Catch-all `if: failure()` step. | ❌ "The workflow failed before posting a review." + link to the run log. |

Draft PRs are silent (the job has `if: github.event.pull_request.draft == false`). All other no-op exits get a comment.

</details>

<details id="triggers-and-skip-conditions">
<summary><b>Triggers and skip conditions</b></summary>

The workflow only runs for **non-draft pull requests**. The job has `if: github.event.pull_request.draft == false`. Mark a PR as Draft to suppress reviews while you iterate.

Recommended caller-side trigger: `pull_request` on `opened, synchronize, reopened, ready_for_review`. The `ready_for_review` event fires when a draft is marked ready, which kicks off the first review on graduation from draft.

Per-PR concurrency is enforced — pushing a new commit cancels any in-flight review for the same PR.

</details>

<details id="permissions">
<summary><b>Permissions</b></summary>

The reusable workflow declares:

```yaml
permissions:
    contents: read
    pull-requests: write
    id-token: write
```

Caller workflows inherit these — no extra `permissions:` block needed unless your repo overrides via org/repo defaults.

</details>

<details id="cost-and-latency">
<summary><b>Cost / latency notes</b></summary>

- One LLM call per changed file, run in parallel (default `parallelism: 4`). A PR touching 30 files = 30 calls in ~8 batches.
- Diff context is `git diff -U30` by default (configurable via `diff_context`). Lowering to `10` typically cuts token cost 30–50% with no review-quality loss.
- Files larger than `max_diff_lines` (default 1500 lines of diff) are skipped — protects against accidental large vendored or generated file commits.
- The whole review is skipped when the PR exceeds `max_files` (default 50). The author gets a PR comment explaining why.
- No prompt caching: every call is independent. If a single PR routinely flags 10+ files, consider lowering `model` to a cheaper tier and bumping `min_severity` to `critical`.

</details>

<details id="troubleshooting">
<summary><b>Troubleshooting</b></summary>

**The workflow ran but no comments appeared.**
Check the "Run AI Review" step logs. Common causes:
- Provider returned non-JSON or an HTTP error — the script prints the body to stderr and continues.
- All findings filtered by `min_severity`.
- All findings filtered by line-not-in-diff guard (LLM hallucinated line numbers).
- The bot found a correct diff and had nothing to flag — check the summary comment for "All good."

**Comments are getting reposted instead of updated.**
The dedup looks at `path`, `line`, and a 50-char prefix of the body. If the LLM rewords the body materially between runs, dedup misses. Tighten the prompt or accept the noise.

**HTTP 401/403 from the provider.**
Confirm `CODE_REVIEW_API_KEY` is set in the calling repo's secrets *and* mapped in the caller workflow's `secrets:` block (the canonical name `CODE_REVIEW_API_KEY` must appear on the right side). `secrets: inherit` works too if the calling repo has a secret literally named `CODE_REVIEW_API_KEY`.

**`actions/checkout` fails fetching the reusable workflow's repo.**
The reusable workflow does a second checkout of `SamyakTechLabs/.github@main` to access `call_api.py`. This repo is public, so the default `GITHUB_TOKEN` is sufficient. If the org makes this repo private later, callers will need to pass a PAT with cross-repo read access.

**Want to test against a single file without a real PR.**
Run the helper script locally:

```bash
export CODE_REVIEW_API_KEY=sk-...
python3 .github/scripts/code-review/call_api.py \
    --provider openai --model gpt-4o \
    --system-prompt-file system.txt \
    --user-prompt-file prompt.txt
```

It prints the assistant text to stdout — useful for tweaking the prompt or sanity-checking a new provider config.

</details>
