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

### S3 file sanitizer Lambda

A drop-in AWS Lambda that sanitizes uploaded files in place on S3 — strips
JavaScript from PDFs, EXIF/metadata from images, and unsafe tags/attributes from
SVGs. Bucket- and region-agnostic and fully configurable; an interactive script
generates the config and a single deploy script provisions the role, layer,
function, and triggers.

→ **[file-sanitizer/README.md](./file-sanitizer/README.md)** — quick start, configuration, AWS permissions setup, and testing.

Quick example:

```bash
cd file-sanitizer
./configure.sh        # interactive: region, bucket(s), naming, limits
./deploy.sh           # provisions everything from the generated config
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
file-sanitizer/
    README.md                          # full sanitizer docs + AWS permissions setup
    lambda_function.py                 # the sanitizer (generic, S3-event driven)
    requirements.txt                   # Pillow, PyPDF2, defusedxml
    configure.sh                       # interactive config generator
    deploy.sh                          # provisions role + layer + function + triggers
    sanitizer.config.example           # documented config template
profile/
    README.md                          # rendered on the org's GitHub page
```
