"""Shared fakes for the Rus to Prompt staged-flow tests."""

from types import SimpleNamespace


def staged_args(
    batch_size=10, confidence_referee="local", local_confidence_models=None, hybrid_fallback="gemini", out_dir="."
):
    return SimpleNamespace(
        benchmark_mode="staged",
        translator_provider="local",
        analyzer_provider="local",
        confidence_referee=confidence_referee,
        confidence_model="judge-model",
        confidence_reasoning_effort="medium",
        confidence_batch_size=batch_size,
        local_confidence_models=local_confidence_models or ["judge-model"],
        hybrid_confidence_online_model="gemini-judge",
        hybrid_confidence_fallback_referee=hybrid_fallback,
        hybrid_confidence_local_threshold=0.80,
        hybrid_confidence_disagreement_threshold=0.15,
        translation_confidence_threshold=0.75,
        codex_bin="codex",
        gemini_bin="gemini",
        codex_stage_timeout=30,
        gemini_stage_timeout=30,
        model_profile="gpt-5.5",
        stage_cooldown_seconds=0,
        control_file=None,
        out_dir=out_dir,
    )


def translation_payload(translation):
    return {
        "status": "ok",
        "translation_status": "translated",
        "translation": translation,
        "source_language": "ru",
        "warnings": [],
    }


def improved_payload(translation, model):
    return {
        "status": "ok",
        "improved_prompt": f"{translation['translation']} improved by {model}",
        "warnings": [],
    }, 2.0


def judge_result(kwargs, value):
    return {
        "provider": kwargs["provider"],
        "model": kwargs["model"],
        "stage": kwargs["stage"],
        "status": "ok",
        "confidence": value,
        "verdict": "pass",
        "warnings": [],
    }


def fake_confidence(items, **kwargs):
    return {
        item_id: judge_result(kwargs, confidence_value_for(result, kwargs["stage"])) for item_id, _case, result in items
    }


def confidence_value_for(result, stage):
    if stage == "translation":
        return {
            "translator-a": 0.40,
            "translator-b": 0.92,
        }[result.translator_model]
    return 0.88
