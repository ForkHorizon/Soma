"""Optional cloud referee for packet evidence quality.

This stage sends only compact task/evidence metadata, not source previews, to a
configured cloud model. It is opt-in and must never block deterministic packets.
"""
import asyncio
import json
import os
import time
import urllib.error
import urllib.request

from .config import DEFAULT_OPENAI_REFEREE_MODEL
from .ranker import _estimate_stage_tokens


def _string_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return [str(item) for item in value if str(item).strip()]
    if isinstance(value, str):
        return [value] if value.strip() else []
    return [str(value)]


def cloud_referee_provider():
    provider = (
        os.environ.get("SOMA_CLOUD_REFEREE_PROVIDER")
        or os.environ.get("SOMA_REFEREE_PROVIDER")
        or ""
    ).strip().lower()
    enabled = os.environ.get("SOMA_CLOUD_REFEREE", "").strip().lower()
    if not provider and enabled in {"1", "true", "yes", "on"}:
        provider = "openai"
    if provider in {"off", "none", "false", "0"}:
        return ""
    return provider


def cloud_referee_enabled():
    return cloud_referee_provider() == "openai"


def cloud_referee_policy():
    policy = (
        os.environ.get("SOMA_CLOUD_REFEREE_POLICY")
        or "degraded_only"
    ).strip().lower()
    if policy in {"always", "degraded_only"}:
        return policy
    return "degraded_only"


def cloud_referee_should_run(evidence_quality):
    if not cloud_referee_enabled():
        return False
    if cloud_referee_policy() == "always":
        return True
    evidence_quality = evidence_quality or {}
    if evidence_quality.get("status") != "ok":
        return True
    if evidence_quality.get("plan_alignment_status") not in {None, "ok"}:
        return True
    for key in ("missing_required_evidence", "excluded_context_selected", "referee_missing_context"):
        if evidence_quality.get(key):
            return True
    return False


def _openai_api_key():
    return os.environ.get("SOMA_OPENAI_API_KEY") or os.environ.get("OPENAI_API_KEY")


def _openai_model():
    return os.environ.get("SOMA_OPENAI_REFEREE_MODEL") or DEFAULT_OPENAI_REFEREE_MODEL


def _openai_endpoint():
    return os.environ.get("SOMA_OPENAI_RESPONSES_URL") or "https://api.openai.com/v1/responses"


def cloud_referee_payload(prompt, collection_plan, preflight, evidence_items, evidence_quality):
    return {
        "prompt": prompt,
        "packet_mode": (preflight or {}).get("packet_mode"),
        "collection_plan": collection_plan or {},
        "evidence_quality": evidence_quality or {},
        "selected_evidence": [
            {
                "id": index,
                "path": item.get("path"),
                "kind": item.get("kind"),
                "reason": item.get("reason"),
                "symbols": (item.get("symbols") or [])[:10],
            }
            for index, item in enumerate(evidence_items or [])
        ],
    }


def _extract_response_text(decoded):
    if not isinstance(decoded, dict):
        return ""
    if isinstance(decoded.get("output_text"), str):
        return decoded["output_text"]
    chunks = []
    for item in decoded.get("output") or []:
        if not isinstance(item, dict):
            continue
        for content in item.get("content") or []:
            if isinstance(content, dict):
                text = content.get("text")
                if isinstance(text, str):
                    chunks.append(text)
    if chunks:
        return "\n".join(chunks)
    message = decoded.get("message")
    if isinstance(message, dict):
        content = message.get("content")
        if isinstance(content, str):
            return content
    return ""


def _extract_json_object(text):
    try:
        decoded = json.loads(text)
        return decoded if isinstance(decoded, dict) else None
    except Exception:
        pass
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end <= start:
        return None
    try:
        decoded = json.loads(text[start:end + 1])
        return decoded if isinstance(decoded, dict) else None
    except Exception:
        return None


def _call_openai_referee(user_payload, timeout):
    api_key = _openai_api_key()
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY or SOMA_OPENAI_API_KEY is not configured")
    body = {
        "model": _openai_model(),
        "input": [
            {
                "role": "system",
                "content": (
                    "You are a packet evidence referee. Review whether selected local evidence "
                    "is sufficient for the task and collection plan. Use only metadata; do not "
                    "invent files or facts. Return JSON only: "
                    "{\"status\":\"ok|degraded\",\"missing_evidence\":[\"...\"],"
                    "\"recommended_additions\":[\"...\"],\"warnings\":[\"...\"],"
                    "\"notes\":[\"...\"]}. Recommend at most 3 evidence kinds or concrete "
                    "repo-relative paths."
                ),
            },
            {"role": "user", "content": user_payload},
        ],
        "max_output_tokens": 450,
    }
    request = urllib.request.Request(
        _openai_endpoint(),
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        decoded = json.loads(response.read().decode("utf-8", errors="replace"))
    return _extract_response_text(decoded)


async def referee_evidence_with_cloud_model(prompt, collection_plan, preflight, evidence_items, evidence_quality):
    provider = cloud_referee_provider()
    stage = {
        "stage": "cloud_referee",
        "provider": provider or "off",
        "model": _openai_model() if provider == "openai" else None,
        "candidate_count_after": len(evidence_items or []),
    }
    if provider != "openai":
        return {}, {**stage, "status": "skipped", "notes": ["cloud referee disabled"]}
    payload = cloud_referee_payload(prompt, collection_plan, preflight, evidence_items, evidence_quality)
    user_payload = json.dumps(payload)
    start = time.monotonic()
    stage["candidate_tokens_before"] = _estimate_stage_tokens(user_payload)
    try:
        text = await asyncio.to_thread(
            _call_openai_referee,
            user_payload,
            float(os.environ.get("SOMA_CLOUD_REFEREE_TIMEOUT", "30")),
        )
    except (urllib.error.URLError, TimeoutError, RuntimeError, ValueError, OSError) as exc:
        return {}, {**stage, "status": "failed", "error": str(exc), "duration_ms": (time.monotonic() - start) * 1000}
    decoded = _extract_json_object(text or "")
    if not isinstance(decoded, dict):
        return {}, {**stage, "status": "failed", "error": "invalid cloud_referee JSON", "duration_ms": (time.monotonic() - start) * 1000}
    result = {
        "status": str(decoded.get("status") or "ok"),
        "missing_evidence": _string_list(decoded.get("missing_evidence"))[:6],
        "recommended_additions": _string_list(decoded.get("recommended_additions"))[:6],
        "warnings": _string_list(decoded.get("warnings"))[:6],
        "notes": _string_list(decoded.get("notes"))[:6],
    }
    return result, {
        **stage,
        "status": "ok",
        "referee_status": result["status"],
        "notes": (result["warnings"] + result["missing_evidence"] + result["recommended_additions"] + result["notes"])[:4],
        "duration_ms": (time.monotonic() - start) * 1000,
    }


def apply_cloud_referee_to_quality(evidence_quality, referee_result):
    if not referee_result:
        return evidence_quality
    updated = dict(evidence_quality or {})
    warnings = list(updated.get("warnings") or [])
    warnings.extend(referee_result.get("warnings") or [])
    missing = _string_list(referee_result.get("missing_evidence"))
    additions = _string_list(referee_result.get("recommended_additions"))
    if missing or additions:
        warnings.append("Cloud referee requested more evidence.")
        updated["referee_missing_context"] = list(dict.fromkeys(missing + additions))[:6]
    if referee_result.get("status") == "degraded" or missing:
        updated["status"] = "degraded"
    updated["warnings"] = list(dict.fromkeys(warnings))[:10]
    return updated
