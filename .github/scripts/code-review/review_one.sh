#!/usr/bin/env bash
#
# Per-file LLM review. Designed to be invoked in parallel via xargs -P.
#
# Usage:   review_one.sh <path-to-diff-file-under-diffs/>
# Exit:    0 = success or intentional skip (empty diff / over MAX_DIFF_LINES)
#          1 = failure (API error or invalid JSON response)
#
# Required env:
#   PR_TITLE
#   MIN_SEVERITY
#   MAX_DIFF_LINES
#   REPO_CONTEXT
#   ACCEPTED_PATTERNS
#   EXISTING_INLINE        JSON array (string) of prior bot inline comments
#   EXISTING_SUMMARY       JSON array (string) of prior bot summary comments
#   SYSTEM_PROMPT_FILE     Path to file containing the system prompt
#   PROVIDER, MODEL, API_URL, API_FORMAT, EXTRA_HEADERS
#   CODE_REVIEW_API_KEY    Provider API key
#   CALL_API_SCRIPT        Path to call_api.py
#   REVIEW_OUTPUT_DIR      Where per-file review JSON lands
#   REVIEW_LOG_DIR         Where per-file logs land

set -uo pipefail

DIFF_FILE="$1"
FILE=$(echo "$DIFF_FILE" | sed 's|diffs/||' | sed 's|\.diff$||')
SAFE_NAME=$(echo "$FILE" | tr '/' '_')
LOG="${REVIEW_LOG_DIR}/${SAFE_NAME}.log"

# Redirect this whole script's output to the per-file log so parallel runs
# don't interleave. The parent workflow concatenates logs in sorted order
# once all reviews complete.
exec >"$LOG" 2>&1

echo "::group::Review $FILE"

if [ ! -s "$DIFF_FILE" ]; then
    echo "Empty diff, skipping"
    echo "::endgroup::"
    exit 0
fi

LINES=$(wc -l < "$DIFF_FILE")
if [ "$LINES" -gt "$MAX_DIFF_LINES" ]; then
    echo "Skipping $FILE — too many lines ($LINES), likely generated"
    echo "::endgroup::"
    exit 0
fi

DIFF_CONTENT=$(cat "$DIFF_FILE")
FILE_HEADER=$(git show HEAD:"$FILE" 2>/dev/null | head -100 || echo "")
FILE_EXISTING=$(echo "$EXISTING_INLINE" | jq --arg file "$FILE" '[.[] | select(.path == $file)]')

USER_PROMPT_FILE="/tmp/prompt-${SAFE_NAME}.txt"
cat > "$USER_PROMPT_FILE" << PROMPT
## Pull Request
Title: ${PR_TITLE}

## Repository Context
${REPO_CONTEXT}

Accepted patterns (do not flag these):
${ACCEPTED_PATTERNS}

## File: ${FILE}

### File header (imports, types, class declaration):
${FILE_HEADER}

### Diff:
${DIFF_CONTENT}

## Prior review comments on this file (do not repeat or contradict these):
${FILE_EXISTING}

## Prior summary comments (do not repeat or contradict these):
${EXISTING_SUMMARY}

---

Review ONLY the changed lines (+ lines in the diff).

For each issue you flag, you MUST provide:
1. The exact new file line number
2. A concrete failure scenario: what input, state, or sequence causes this to break
3. A concrete fix

If you cannot describe a specific way the code breaks, do NOT flag it.

### What to flag:
- Bug: reachable condition where code produces wrong result, crashes, or hangs
- Security: concrete exploit path (injection, auth bypass, SSRF, secret leak)
- Data integrity: silent data loss, missing rollback, race condition with real trigger
- Breaking contract: return type change, removed required field, changed API behavior

### What to NEVER flag:
- Style, formatting, naming, comments, documentation
- Patterns already established in the file
- Missing error handling for conditions the surrounding code already guards against
- Hypothetical issues requiring unreachable conditions
- Anything on lines NOT changed in this diff
- Issues already raised in prior review comments above

Return ONLY valid JSON. No markdown. No preamble.

{
    "summary": "One sentence: what this change does. Risk: low|medium|high.",
    "comments": [
        {
            "line": <new_file_line_number>,
            "severity": "critical|warning",
            "comment": "**Bug/Security/Data/Breaking**: what breaks and when. Fix: specific fix."
        }
    ]
}
PROMPT

if ! TEXT=$(python3 "$CALL_API_SCRIPT" \
        --provider "$PROVIDER" \
        --model "$MODEL" \
        --system-prompt-file "$SYSTEM_PROMPT_FILE" \
        --user-prompt-file "$USER_PROMPT_FILE" \
        --api-url "$API_URL" \
        --api-format "$API_FORMAT" \
        --extra-headers "$EXTRA_HEADERS"); then
    echo "API call failed for $FILE — skipping"
    echo "::endgroup::"
    exit 1
fi

# Strip optional ```json fences the model may emit.
TEXT=$(printf '%s' "$TEXT" | sed '1{/^```/d}' | sed '${/^```/d}')

if ! echo "$TEXT" | jq empty 2>/dev/null; then
    echo "Skipping invalid JSON response for $FILE"
    echo "::endgroup::"
    exit 1
fi

TEXT=$(echo "$TEXT" | jq \
    --arg min "$MIN_SEVERITY" '
    def sev_rank: if . == "critical" then 2 elif . == "warning" then 1 else 0 end;
    def min_rank: $min | sev_rank;
    .comments = [.comments[] | select((.severity | sev_rank) >= min_rank)]
    | .
')

echo "$TEXT" | jq --arg file "$FILE" '. + {file: $file}' > "${REVIEW_OUTPUT_DIR}/${SAFE_NAME}.json"
echo "Wrote ${REVIEW_OUTPUT_DIR}/${SAFE_NAME}.json"
echo "::endgroup::"
