# SamyakTechLabs `.github`

This is the org's shared `.github` repository. Organisation-wide community-health files, the org profile, and reusable GitHub Actions workflows live here so any repo in the org can consume them.

## Shared resources

### Reusable code-review workflow

Provider-agnostic AI code review for pull requests — works with OpenAI, Anthropic, Z.AI, Gemini, xAI, DeepSeek, OpenRouter, or any custom endpoint. Posts inline + summary PR comments and notifies the author when reviews are skipped or fail.

→ **[code-review/README.md](./code-review/README.md)** — full documentation, caller examples, configuration reference.

Quick example:

```yaml
# .github/workflows/code-review.yml in any consumer repo
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

## Repo layout

```
.github/
    workflows/code-review.yml          # the reusable workflow
    scripts/code-review/
        call_api.py                    # provider-agnostic LLM client
        review_one.sh                  # per-file review (run in parallel)
code-review/
    README.md                          # full code-review docs
    code-review.example.yml            # sample caller workflow
profile/
    README.md                          # rendered on the org's GitHub page
```
