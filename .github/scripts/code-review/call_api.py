#!/usr/bin/env python3
"""
Provider-agnostic LLM caller for the org code-review reusable workflow.

Reads a system prompt and a user prompt from files, calls the chosen
provider's chat/generation endpoint, and prints the assistant text to
stdout.

Inputs are passed via CLI flags and environment:
    --provider        Named provider (openai|anthropic|zai|gemini|xai|deepseek|openrouter|custom)
    --model           Model identifier (e.g. gpt-4o, claude-sonnet-4-6, glm-5.1, gemini-2.5-pro)
    --system-prompt-file   Path to file containing system prompt
    --user-prompt-file     Path to file containing user prompt
    --api-url         Required when provider=custom. Optional override otherwise.
    --api-format      Required when provider=custom: openai|anthropic|gemini.
    --extra-headers   JSON object of additional headers. Values may contain
                      "$CODE_REVIEW_API_KEY" which is replaced from env.
                      Empty values DELETE the corresponding default header.

Environment:
    CODE_REVIEW_API_KEY   The API key (required).

Exit codes:
    0 on success (assistant text on stdout)
    1 on configuration / argument errors
    2 on HTTP / network errors
    3 on response parse errors
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from typing import NoReturn


PROVIDERS = {
    "openai":     {"url": "https://api.openai.com/v1/chat/completions",                                "format": "openai"},
    "anthropic":  {"url": "https://api.anthropic.com/v1/messages",                                     "format": "anthropic"},
    "zai":        {"url": "https://api.z.ai/api/coding/paas/v4/chat/completions",                      "format": "openai", "zai_thinking_disabled": True},
    "gemini":     {"url": "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent", "format": "gemini"},
    "xai":        {"url": "https://api.x.ai/v1/chat/completions",                                      "format": "openai"},
    "deepseek":   {"url": "https://api.deepseek.com/v1/chat/completions",                              "format": "openai"},
    "openrouter": {"url": "https://openrouter.ai/api/v1/chat/completions",                             "format": "openai"},
}

VALID_FORMATS = {"openai", "anthropic", "gemini"}


def resolve_provider(provider, api_url, api_format, model):
    if provider == "custom":
        if not api_url or not api_format:
            die("provider=custom requires both --api-url and --api-format", code=1)
        if api_format not in VALID_FORMATS:
            die(f"--api-format must be one of {sorted(VALID_FORMATS)}", code=1)
        return {"url": api_url, "format": api_format, "zai_thinking_disabled": False}

    cfg = PROVIDERS.get(provider)
    if not cfg:
        die(f"unknown provider '{provider}'. Known: {sorted(PROVIDERS)} or 'custom'.", code=1)

    url = api_url or cfg["url"]
    if "{model}" in url:
        url = url.replace("{model}", model)

    fmt = api_format or cfg["format"]
    if fmt not in VALID_FORMATS:
        die(f"--api-format must be one of {sorted(VALID_FORMATS)}", code=1)

    return {
        "url": url,
        "format": fmt,
        "zai_thinking_disabled": cfg.get("zai_thinking_disabled", False),
    }


def default_headers(fmt, api_key):
    if fmt == "openai":
        return {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        }
    if fmt == "anthropic":
        return {
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "Content-Type": "application/json",
        }
    if fmt == "gemini":
        return {
            "x-goog-api-key": api_key,
            "Content-Type": "application/json",
        }
    die(f"unsupported api_format '{fmt}'", code=1)


def interpolate(value, api_key):
    return value.replace("$CODE_REVIEW_API_KEY", api_key)


def merge_extra_headers(base, extra_raw, api_key):
    if not extra_raw:
        return base
    try:
        extra = json.loads(extra_raw)
    except json.JSONDecodeError as e:
        die(f"--extra-headers is not valid JSON: {e}", code=1)
    if not isinstance(extra, dict):
        die("--extra-headers must be a JSON object", code=1)

    merged = dict(base)
    for k, v in extra.items():
        if not isinstance(v, str):
            die(f"--extra-headers value for '{k}' must be a string", code=1)
        if v == "":
            merged.pop(k, None)
        else:
            merged[k] = interpolate(v, api_key)
    return merged


def build_payload(fmt, model, system_prompt, user_prompt, zai_thinking_disabled):
    if fmt == "openai":
        payload = {
            "model": model,
            "temperature": 0,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
        }
        if zai_thinking_disabled:
            payload["thinking"] = {"type": "disabled"}
        return payload

    if fmt == "anthropic":
        return {
            "model": model,
            "max_tokens": 4096,
            "temperature": 0,
            "system": system_prompt,
            "messages": [
                {"role": "user", "content": user_prompt},
            ],
        }

    if fmt == "gemini":
        return {
            "system_instruction": {"parts": [{"text": system_prompt}]},
            "contents": [
                {"role": "user", "parts": [{"text": user_prompt}]},
            ],
            "generationConfig": {"temperature": 0},
        }

    die(f"unsupported api_format '{fmt}'", code=1)


def extract_text(fmt, response):
    try:
        if fmt == "openai":
            return response["choices"][0]["message"]["content"]
        if fmt == "anthropic":
            parts = response["content"]
            for part in parts:
                if part.get("type") == "text":
                    return part["text"]
            return parts[0].get("text", "")
        if fmt == "gemini":
            cand = response["candidates"][0]
            return cand["content"]["parts"][0]["text"]
    except (KeyError, IndexError, TypeError) as e:
        die(f"could not extract assistant text from response ({fmt}): {e}\nresponse: {json.dumps(response)[:500]}", code=3)
    die(f"unsupported api_format '{fmt}'", code=1)


def post(url, headers, payload):
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            detail = e.read().decode("utf-8", errors="replace")[:1000]
        except Exception:
            detail = "<no body>"
        die(f"HTTP {e.code} from {url}\n{detail}", code=2)
    except urllib.error.URLError as e:
        die(f"network error calling {url}: {e.reason}", code=2)
    except json.JSONDecodeError as e:
        die(f"response from {url} was not valid JSON: {e}", code=3)


def die(msg: str, code: int = 1) -> NoReturn:
    print(f"call_api.py: {msg}", file=sys.stderr)
    sys.exit(code)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--provider", required=True)
    p.add_argument("--model", required=True)
    p.add_argument("--system-prompt-file", required=True)
    p.add_argument("--user-prompt-file", required=True)
    p.add_argument("--api-url", default="")
    p.add_argument("--api-format", default="")
    p.add_argument("--extra-headers", default="")
    args = p.parse_args()

    api_key = os.environ.get("CODE_REVIEW_API_KEY", "")
    if not api_key:
        die("CODE_REVIEW_API_KEY env var is required", code=1)

    cfg = resolve_provider(args.provider, args.api_url, args.api_format, args.model)

    with open(args.system_prompt_file, "r", encoding="utf-8") as f:
        system_prompt = f.read()
    with open(args.user_prompt_file, "r", encoding="utf-8") as f:
        user_prompt = f.read()

    headers = default_headers(cfg["format"], api_key)
    headers = merge_extra_headers(headers, args.extra_headers, api_key)

    payload = build_payload(
        cfg["format"],
        args.model,
        system_prompt,
        user_prompt,
        cfg["zai_thinking_disabled"],
    )

    response = post(cfg["url"], headers, payload)
    text = extract_text(cfg["format"], response)
    sys.stdout.write(text)


if __name__ == "__main__":
    main()
