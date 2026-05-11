#!/usr/bin/env python3
"""Shared token estimation profiles for Soma analytics and benchmarks."""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class TokenProfile:
    key: str
    label: str
    chars_per_token: float


PROFILES: dict[str, TokenProfile] = {
    "gpt-5.5": TokenProfile("gpt-5.5", "GPT-5.5", 3.2),
    "openai": TokenProfile("openai", "OpenAI generic", 3.4),
    "gemini": TokenProfile("gemini", "Gemini generic", 3.5),
    "claude": TokenProfile("claude", "Claude generic", 3.3),
    "local": TokenProfile("local", "Local model generic", 3.8),
    "fallback": TokenProfile("fallback", "Fallback", 4.0),
}


def profile_for(name: str | None) -> TokenProfile:
    lowered = (name or "fallback").lower()
    if lowered in PROFILES:
        return PROFILES[lowered]
    if "gpt" in lowered or "openai" in lowered or lowered.startswith(("o3", "o4")):
        return PROFILES["openai"]
    if "gemini" in lowered or "gemma" in lowered:
        return PROFILES["gemini"]
    if "claude" in lowered or "anthropic" in lowered:
        return PROFILES["claude"]
    if "local" in lowered or "ollama" in lowered:
        return PROFILES["local"]
    return PROFILES["fallback"]


def estimate_tokens(text: str, model_profile: str | None = None) -> int:
    profile = profile_for(model_profile)
    return max(1, int(len(text or "") / profile.chars_per_token))


def estimate_payload(text: str, model_profile: str | None = None) -> dict[str, Any]:
    profile = profile_for(model_profile)
    return {
        "model_profile": profile.key,
        "label": profile.label,
        "chars_per_token": profile.chars_per_token,
        "characters": len(text or ""),
        "estimated_tokens": estimate_tokens(text, profile.key),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Estimate Soma token counts.")
    parser.add_argument("--model-profile", default="fallback")
    parser.add_argument("--text", default=None)
    parser.add_argument("--stdin", action="store_true")
    parser.add_argument("--profiles", action="store_true")
    args = parser.parse_args()

    if args.profiles:
        print(json.dumps({key: profile.__dict__ for key, profile in PROFILES.items()}, indent=2, sort_keys=True))
        return 0

    text = sys.stdin.read() if args.stdin else (args.text or "")
    print(json.dumps(estimate_payload(text, args.model_profile), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
