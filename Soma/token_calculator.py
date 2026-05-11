#!/usr/bin/env python3
"""Shared token estimation profiles for Soma analytics and benchmarks."""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class TokenProfile:
    key: str
    label: str
    chars_per_token: float
    aliases: tuple[str, ...] = ()
    exact_encoding: str | None = None


FALLBACK_PROFILES: dict[str, TokenProfile] = {
    "gpt-5.5": TokenProfile("gpt-5.5", "GPT-5.5", 3.2, ("gpt-5.5",), "cl100k_base"),
    "openai": TokenProfile("openai", "OpenAI generic", 3.4, ("gpt", "openai", "o3", "o4"), "cl100k_base"),
    "gemini": TokenProfile("gemini", "Gemini generic", 3.5, ("gemini", "gemma"), None),
    "claude": TokenProfile("claude", "Claude generic", 3.3, ("claude", "anthropic"), None),
    "local": TokenProfile("local", "Local model generic", 3.8, ("local", "ollama"), None),
    "fallback": TokenProfile("fallback", "Fallback", 4.0, (), None),
}


def _profile_path() -> Path:
    return Path(__file__).with_name("token_profiles.json")


def _load_profiles() -> dict[str, TokenProfile]:
    try:
        data = json.loads(_profile_path().read_text(encoding="utf-8"))
        profiles: dict[str, TokenProfile] = {}
        for item in data.get("profiles", []):
            profile = TokenProfile(
                key=str(item["key"]),
                label=str(item["label"]),
                chars_per_token=float(item["chars_per_token"]),
                aliases=tuple(str(alias).lower() for alias in item.get("aliases", [])),
                exact_encoding=item.get("exact_encoding"),
            )
            profiles[profile.key] = profile
        if "fallback" in profiles:
            return profiles
    except Exception:
        pass
    return FALLBACK_PROFILES


PROFILES: dict[str, TokenProfile] = _load_profiles()
_ENCODING_CACHE: dict[str, Any] = {}


def profile_for(name: str | None) -> TokenProfile:
    lowered = (name or "fallback").lower()
    if lowered in PROFILES:
        return PROFILES[lowered]
    for profile in PROFILES.values():
        if any(alias and (alias in lowered or lowered.startswith(alias)) for alias in profile.aliases):
            return profile
    return PROFILES["fallback"]


def _encoding_for(profile: TokenProfile) -> Any | None:
    if not profile.exact_encoding:
        return None
    if profile.exact_encoding in _ENCODING_CACHE:
        return _ENCODING_CACHE[profile.exact_encoding]
    try:
        import tiktoken

        encoding = tiktoken.get_encoding(profile.exact_encoding)
        _ENCODING_CACHE[profile.exact_encoding] = encoding
        return encoding
    except Exception:
        _ENCODING_CACHE[profile.exact_encoding] = None
        return None


def estimate_tokens(text: str, model_profile: str | None = None, *, exact: bool = True) -> int:
    profile = profile_for(model_profile)
    if exact:
        encoding = _encoding_for(profile)
        if encoding is not None:
            try:
                return max(1, len(encoding.encode(text or "", allowed_special="all")))
            except Exception:
                pass
    return estimate_tokens_for_chars(len(text or ""), profile.key)


def estimate_tokens_for_chars(characters: int, model_profile: str | None = None) -> int:
    profile = profile_for(model_profile)
    return max(1, int(max(0, characters) / profile.chars_per_token))


def estimate_payload(text: str, model_profile: str | None = None) -> dict[str, Any]:
    profile = profile_for(model_profile)
    encoding = _encoding_for(profile)
    estimator = "tiktoken" if encoding is not None else "chars_per_token"
    return {
        "model_profile": profile.key,
        "label": profile.label,
        "chars_per_token": profile.chars_per_token,
        "estimator": estimator,
        "exact_encoding": profile.exact_encoding if encoding is not None else None,
        "characters": len(text or ""),
        "estimated_tokens": estimate_tokens(text, profile.key),
    }


def profiles_payload() -> dict[str, Any]:
    return {
        key: {
            "key": profile.key,
            "label": profile.label,
            "chars_per_token": profile.chars_per_token,
            "aliases": list(profile.aliases),
            "exact_encoding": profile.exact_encoding,
        }
        for key, profile in PROFILES.items()
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Estimate Soma token counts.")
    parser.add_argument("--model-profile", default="fallback")
    parser.add_argument("--text", default=None)
    parser.add_argument("--stdin", action="store_true")
    parser.add_argument("--profiles", action="store_true")
    args = parser.parse_args()

    if args.profiles:
        print(json.dumps(profiles_payload(), indent=2, sort_keys=True))
        return 0

    text = sys.stdin.read() if args.stdin else (args.text or "")
    print(json.dumps(estimate_payload(text, args.model_profile), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
