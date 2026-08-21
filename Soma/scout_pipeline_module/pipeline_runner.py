"""Stateful runner for gather orchestration."""

import json
import os

from .config import *
from soma_audit import (
    build_missing_evidence,
    build_prepare_audit,
    compact_response_audit,
    ensure_context,
    hash_text,
    write_audit_log_event,
    write_prepare_audit,
)
from soma_language_optimizer import optimize_prompt_language
from soma_token_savings import (
    build_estimated_context_reduction,
    build_operation_savings,
    build_task_candidate_baseline,
    build_token_savings,
    finalize_operation_savings_response_tokens,
)


async def run_gather_impl(user_prompt, project_root, recent_roots_json, **kwargs):
    runner = GatherRunner(user_prompt, project_root, recent_roots_json, **kwargs)
    await runner.run()


class GatherRunner:
    def __init__(self, user_prompt, project_root, recent_roots_json, **kwargs):
        self.user_prompt = user_prompt
        self.project_root = project_root
        self.recent_roots_json = recent_roots_json
        self.token_budget = kwargs["token_budget"]
        self.use_local_summary = kwargs["use_local_summary"]
        self.analysis_depth = (
            kwargs["analysis_depth"] if kwargs["analysis_depth"] in ANALYSIS_DEPTHS else "deterministic"
        )
        self.packet_profile = (
            kwargs["packet_profile"] if kwargs["packet_profile"] in {"standard", "prompt_compiler"} else "standard"
        )
        self.planning_mode = kwargs["planning_mode"] if kwargs["planning_mode"] in {"off", "local", "auto"} else "auto"
        self.graph_query = kwargs["graph_query"]
        self.graph_suggestion_lines = kwargs["graph_suggestion_lines"]
        self.graph_suggested_paths = kwargs["graph_suggested_paths"]
        self.graph_hints_allowed = kwargs["graph_hints_allowed"]
        self.graph_matches_scope = kwargs["graph_matches_scope"]
        self.token_model_profile = os.environ.get("SOMA_TOKEN_MODEL_PROFILE", "gpt-5.5")
        self.audit_context = ensure_context(workflow="packet_mode")

    async def run(self):
        self._normalize_prompt()
        self._audit_start()
        if self._emit_direct_if_possible():
            return
        if not self._validate_project_root():
            return
        await self._load_project_context()
        await self._select_and_rank_evidence()
        await self._score_and_repair_evidence()
        await self._summarize()
        self._apply_graph_hints()
        self._build_bundle()
        self._finalize_packet()
        self._write_audit()
        print(json.dumps(self.bundle))

    def _normalize_prompt(self):
        self.normalized_prompt, self.language_optimization = optimize_prompt_language(
            self.user_prompt, self.token_model_profile
        )
        self.selection_prompt = (
            self.normalized_prompt + "\n" + self.user_prompt
            if self.normalized_prompt != self.user_prompt
            else self.normalized_prompt
        )

    def _audit_start(self):
        write_audit_log_event(
            "audit_start",
            status="ok",
            run_id=self.audit_context["run_id"],
            task_id=self.audit_context["task_id"],
            workflow=self.audit_context["workflow"],
            project_root=self.project_root,
            extra={"prompt_hash": hash_text(self.user_prompt)},
        )

    def _emit_direct_if_possible(self):
        from .classifier import classify_prompt_intent, prompt_terms
        from .packet import bundle_for_direct_pass

        self.intent = classify_prompt_intent(self.normalized_prompt)
        if self.intent["needs_gather"]:
            return False
        preflight = {
            "intent": self.intent,
            "packet_mode": "direct",
            "confidence": self.intent["confidence"],
            "terms": prompt_terms(self.selection_prompt),
            "explicit_paths": [],
            "changed_files": [],
            "changed_paths": [],
            "log_candidates": [],
            "error_paths": [],
            "candidate_paths": [],
        }
        bundle = bundle_for_direct_pass(
            self.normalized_prompt,
            self.intent["reason"],
            self.project_root,
            self.token_budget,
            self.analysis_depth,
            preflight,
        )
        bundle["language_optimization"] = self.language_optimization
        bundle["token_savings"] = build_token_savings(
            packet=bundle.get("codex_packet") or "",
            budget=self.token_budget,
            budget_tokens=TOKEN_BUDGETS[self.token_budget],
            model_profile=self.token_model_profile,
            warnings=["Direct prompt did not need local evidence, so no raw-context baseline was available."],
        )
        bundle["estimated_context_reduction"] = bundle["token_savings"].get("estimated_context_reduction")
        bundle["operation_savings"] = bundle["token_savings"].get("operation_savings")
        bundle["audit"] = compact_response_audit(self._direct_audit(bundle))
        print(json.dumps(bundle))
        return True

    def _direct_audit(self, bundle):
        report = build_prepare_audit(
            context=self.audit_context,
            status="ok",
            project_root=self.project_root,
            project_type=None,
            original_prompt=self.user_prompt,
            normalized_prompt=self.normalized_prompt,
            packet=bundle.get("codex_packet") or "",
            estimated_tokens=bundle.get("estimated_tokens"),
            evidence_items=[],
            missing_evidence={
                "status": "ok",
                "reason": self.intent["reason"],
                "unresolved_references": [],
                "found_not_selected": [],
            },
            evidence_quality={"status": "ok", "warnings": []},
            tool_calls_expected=["Run gather again with a concrete code/debug/review goal if evidence is needed."],
            language_optimization=self.language_optimization,
        )
        return write_prepare_audit(report)

    def _validate_project_root(self):
        from .utils import normalize_path

        if not self.project_root:
            print(json.dumps({"error": "This prompt needs project context. Select a project root before relaying it."}))
            return False
        try:
            self.project_root = normalize_path(self.project_root)
        except Exception as exc:
            print(json.dumps({"error": f"Invalid project root: {exc}"}))
            return False
        if not os.path.isdir(self.project_root):
            print(json.dumps({"error": f"Project root does not exist: {self.project_root}"}))
            return False
        return True

    async def _load_project_context(self):
        from .classifier import prompt_terms
        from .collection_plan import plan_collection_with_local_model
        from .discovery import build_repo_index, detect_project_type, iter_project_files
        from .git import get_git_diff_summary, get_git_status
        from .gather import build_preflight, gather_external_evidence

        self.terms = prompt_terms(self.selection_prompt)
        self.project_type, self.type_reason = detect_project_type(self.project_root)
        self.git_status = get_git_status(self.project_root)
        self.git_diff_summary = get_git_diff_summary(self.project_root, self.terms)
        self.discovered = iter_project_files(self.project_root)
        self.repo_index = build_repo_index(self.project_root, self.discovered)
        (
            self.collection_plan,
            self.collection_stage,
            self.collection_plan_source,
            self.collection_plan_warnings,
        ) = await plan_collection_with_local_model(
            self.selection_prompt,
            self.project_root,
            self.project_type,
            self.discovered,
            self.repo_index,
            self.planning_mode,
        )
        self.analysis_stages = [
            self.collection_stage,
            {"stage": "preflight", "status": "ok"},
            {"stage": "deterministic", "status": "ok"},
        ]
        self.preflight = build_preflight(
            self.selection_prompt,
            self.project_root,
            self.project_type,
            self.discovered,
            self.repo_index,
            self.git_status,
            self.git_diff_summary,
            self.collection_plan,
        )
        self.explicit_items = gather_external_evidence(
            self.selection_prompt, self.project_root, self.terms, self.discovered, self.repo_index
        )

    async def _select_and_rank_evidence(self):
        from .gather import select_evidence
        from .ranker import filter_candidates_with_model, rank_evidence_with_model

        limit = MAX_EVIDENCE_ITEMS * 3 if self.analysis_depth in {"ranked", "analyst"} else MAX_EVIDENCE_ITEMS
        self.evidence_items = self._dedupe_evidence(
            self.explicit_items
            + select_evidence(
                self.project_root,
                self.selection_prompt,
                self.project_type,
                self.repo_index,
                self.preflight,
                max_items=limit,
            ),
            limit,
        )
        if self.analysis_depth in {"ranked", "analyst"}:
            self.evidence_items, filter_stage = await filter_candidates_with_model(
                self.normalized_prompt, self.preflight, self.evidence_items, MAX_EVIDENCE_ITEMS
            )
            self.analysis_stages.append(filter_stage)
            ranked_items, rank_stage = await rank_evidence_with_model(
                self.normalized_prompt, self.preflight, self.evidence_items
            )
            self.evidence_items = ranked_items[:MAX_EVIDENCE_ITEMS]
            self.analysis_stages.append(rank_stage)

    def _dedupe_evidence(self, items, limit):
        deduped, seen = [], set()
        for item in items:
            if item["path"] in seen:
                continue
            seen.add(item["path"])
            deduped.append(item)
            if len(deduped) >= limit:
                break
        return deduped

    async def _score_and_repair_evidence(self):
        self._refresh_error_lines_and_quality()
        if self.planning_mode in {"local", "auto"}:
            await self._repair_with_local_referee()
        await self._repair_with_cloud_referee()
        if self.analysis_depth in {"ranked", "analyst"}:
            await self._run_referee_model()

    def _refresh_error_lines_and_quality(self):
        from .gather import assess_evidence_quality, assess_plan_alignment, evidence_policy_summary
        from .parser import find_errors
        from .utils import dedupe_strings

        self.error_lines = dedupe_strings(
            [
                error
                for item in self.evidence_items
                if item.get("kind") == "log"
                for error in find_errors(item.get("preview", ""))
            ]
        )[:MAX_ERROR_LINES]
        self.evidence_quality = assess_evidence_quality(self.selection_prompt, self.evidence_items, self.preflight)
        self.evidence_quality.update(assess_plan_alignment(self.collection_plan, self.evidence_items, self.preflight))
        self.policy_summary = evidence_policy_summary(self.evidence_items, self.project_root, self.project_type)
        if self.policy_summary["warnings"]:
            self.evidence_quality["warnings"] = dedupe_strings(
                (self.evidence_quality.get("warnings") or []) + self.policy_summary["warnings"]
            )[:10]

    async def _repair_with_local_referee(self):
        from .collection_plan import referee_evidence_with_plan_model

        evidence_referee, stage = await referee_evidence_with_plan_model(
            self.selection_prompt, self.collection_plan, self.evidence_items, self.evidence_quality
        )
        self.analysis_stages.append(stage)
        self._apply_repair(evidence_referee, "evidence_repair")

    async def _repair_with_cloud_referee(self):
        from .cloud_referee import (
            apply_cloud_referee_to_quality,
            cloud_referee_should_run,
            referee_evidence_with_cloud_model,
        )

        if not cloud_referee_should_run(self.evidence_quality):
            return
        cloud_referee, stage = await referee_evidence_with_cloud_model(
            self.selection_prompt, self.collection_plan, self.preflight, self.evidence_items, self.evidence_quality
        )
        self.analysis_stages.append(stage)
        if cloud_referee:
            self._apply_repair(cloud_referee, "cloud_evidence_repair")
            self.evidence_quality = apply_cloud_referee_to_quality(self.evidence_quality, cloud_referee)

    def _apply_repair(self, referee_result, stage_name):
        from .gather import repair_evidence_from_plan

        repaired_items, additions = repair_evidence_from_plan(
            self.project_root,
            self.selection_prompt,
            self.project_type,
            self.evidence_items,
            self.collection_plan,
            self.preflight,
            referee_result,
            self.repo_index,
            max_additions=3,
        )
        if not additions:
            return
        self.evidence_items = (self.evidence_items[: max(0, MAX_EVIDENCE_ITEMS - len(additions))] + additions)[
            :MAX_EVIDENCE_ITEMS
        ]
        self._refresh_error_lines_and_quality()
        self.analysis_stages.append(
            {
                "stage": stage_name,
                "status": "ok",
                "candidate_count_after": len(self.evidence_items),
                "notes": [f"Added {len(additions)} evidence item(s) from collection plan repair."],
            }
        )

    async def _run_referee_model(self):
        from .ranker import referee_evidence_with_model

        failed_ranker = any(
            stage.get("stage") == "ranker" and stage.get("status") == "failed"
            for stage in self.analysis_stages
            if isinstance(stage, dict)
        )
        if not failed_ranker:
            self.evidence_quality, referee_stage = await referee_evidence_with_model(
                self.normalized_prompt, self.preflight, self.evidence_items, self.evidence_quality
            )
            self.analysis_stages.append(referee_stage)

    async def _summarize(self):
        from .ranker import (
            analyze_packet_with_model,
            fallback_summary,
            should_use_model_summary,
            summarize_local_ai_stages,
            summarize_with_ollama,
        )
        from .utils import dedupe_strings, parse_recent_roots

        self.model_analysis = None
        if self.analysis_depth == "analyst":
            self.model_analysis, analyst_stage = await analyze_packet_with_model(
                self.normalized_prompt, self.preflight, self.evidence_items, self.error_lines
            )
            self.analysis_stages.append(analyst_stage)
        self.summary = fallback_summary(
            self.normalized_prompt,
            self.project_root,
            self.project_type,
            self.evidence_items,
            self.error_lines,
            self.preflight["packet_mode"],
        )
        await self._maybe_use_local_summary(summarize_with_ollama, should_use_model_summary, dedupe_strings)
        if self.type_reason not in self.summary["assumptions"]:
            self.summary["assumptions"] = [self.type_reason] + list(self.summary.get("assumptions") or [])
        if parse_recent_roots(self.recent_roots_json) and self.project_root not in parse_recent_roots(
            self.recent_roots_json
        ):
            self.summary["assumptions"].append(
                "Selected project root was used as the authoritative scope for gathering."
            )
        self.local_ai_metrics = summarize_local_ai_stages(self.analysis_stages)

    async def _maybe_use_local_summary(self, summarize_with_ollama, should_use_model_summary, dedupe_strings):
        if not self.use_local_summary:
            return
        model_summary = await summarize_with_ollama(
            self.normalized_prompt, self.project_root, self.project_type, self.evidence_items, self.error_lines
        )
        if should_use_model_summary(model_summary):
            self.summary["summary"] = model_summary.get("summary") or self.summary["summary"]
            self.summary["assumptions"] = dedupe_strings(
                self.summary.get("assumptions", []) + list(model_summary.get("assumptions") or [])
            )[:4]
            self.summary["open_questions"] = dedupe_strings(
                self.summary.get("open_questions") or [] + list(model_summary.get("open_questions") or [])
            )[:4]
            self.summary["confidence"] = max(
                self.summary.get("confidence", 0.55), model_summary.get("confidence", 0.55)
            )

    def _apply_graph_hints(self):
        from .gather import (
            assess_evidence_quality,
            assess_plan_alignment,
            evidence_item_from_path,
            evidence_policy_summary,
        )
        from .parser import find_errors
        from .utils import categorize_path, dedupe_strings, is_generated_dependency_path, normalize_path

        self.graph_result = self.graph_query(self.normalized_prompt, self.project_root, budget=1200)
        self.graph_allowed, policy_warning = self.graph_hints_allowed(self.collection_plan)
        scope_warnings = []
        if self.graph_allowed:
            self.graph_allowed, scope_warnings = self.graph_matches_scope(
                self.graph_result, self.collection_plan, self.preflight
            )
        if not self.graph_allowed:
            self.graph_result = {
                **self.graph_result,
                "answers": [],
                "warnings": dedupe_strings(
                    (self.graph_result.get("warnings") or [])
                    + ([policy_warning] if policy_warning else [])
                    + scope_warnings
                ),
            }
        self.graph_suggestions = (
            self.graph_suggestion_lines(self.graph_result)
            if self.graph_allowed and self.packet_profile != "prompt_compiler"
            else []
        )
        self.graph_suggested_paths = self._append_graph_evidence(
            categorize_path, evidence_item_from_path, is_generated_dependency_path, normalize_path
        )
        if self.graph_suggested_paths:
            self.error_lines = dedupe_strings(
                [
                    error
                    for item in self.evidence_items
                    if item.get("kind") == "log"
                    for error in find_errors(item.get("preview", ""))
                ]
            )[:MAX_ERROR_LINES]
            self.evidence_quality = assess_evidence_quality(self.selection_prompt, self.evidence_items, self.preflight)
            self.evidence_quality.update(
                assess_plan_alignment(self.collection_plan, self.evidence_items, self.preflight)
            )
            self.policy_summary = evidence_policy_summary(self.evidence_items, self.project_root, self.project_type)

    def _append_graph_evidence(
        self, categorize_path, evidence_item_from_path, is_generated_dependency_path, normalize_path
    ):
        if not self.graph_allowed or self.packet_profile == "prompt_compiler":
            return []
        selected_paths = {normalize_path(item.get("path")) for item in self.evidence_items if item.get("path")}
        suggested = []
        for path in self.graph_suggested_paths(self.graph_result, self.project_root, max_paths=3):
            normalized = normalize_path(path)
            if is_generated_dependency_path(path, self.project_root):
                continue
            if normalized not in selected_paths:
                category = categorize_path(normalized)
                if category:
                    self.evidence_items = (
                        self.evidence_items[:-1]
                        if len(self.evidence_items) >= MAX_EVIDENCE_ITEMS
                        else self.evidence_items
                    ) + [
                        evidence_item_from_path(
                            normalized,
                            category,
                            "Included because Graphify suggested this file as related to the task.",
                            [],
                        )
                    ]
                    selected_paths.add(normalized)
            suggested.append(normalized)
        return suggested

    def _build_bundle(self):
        from .utils import dedupe_strings

        self.bundle = {
            "mode": "gather",
            "status": self.evidence_quality["status"],
            "original_prompt": self.user_prompt if self.language_optimization.get("source_language") == "en" else None,
            "normalized_prompt": self.normalized_prompt,
            "language_optimization": self.language_optimization,
            "project_root": self.project_root,
            "project_type": self.project_type,
            "routing_decision": "gathered_and_relayed",
            "packet_profile": self.packet_profile,
            "packet_mode": self.preflight["packet_mode"],
            "analysis_depth": self.analysis_depth,
            "analysis_stages": self.analysis_stages,
            "local_ai_metrics": self.local_ai_metrics,
            "collection_plan": self.collection_plan,
            "collection_plan_source": self.collection_plan_source,
            "collection_plan_warnings": self.collection_plan_warnings,
            "preflight": {
                key: value
                for key, value in self.preflight.items()
                if key not in {"changed_paths", "error_paths", "candidate_paths"}
            },
            "model_analysis": self.model_analysis,
            "gather_reason": self.intent["reason"],
            "confidence": self.summary.get("confidence", 0.55),
            "git_status": self.git_status,
            "git_diff": None,
            "git_diff_summary": self.git_diff_summary,
            "repo_index": {
                "cache_path": self.repo_index.get("cache_path"),
                "indexed_file_count": self.repo_index.get("indexed_file_count"),
                "changed_index_entries": self.repo_index.get("changed_index_entries"),
            },
            "token_budget": self.token_budget,
            "gathered_files": {
                item["path"]: {"tool": item["kind"], "preview": item["preview"][:300]} for item in self.evidence_items
            },
            "evidence_items": self.evidence_items,
            "evidence_quality": self.evidence_quality,
            "error_lines": self.error_lines,
            "context_summary": self.summary.get("summary") or "",
            "graph_suggestions": self.graph_suggestions,
            "open_questions": dedupe_strings(
                (
                    [
                        f"Missing required evidence: {', '.join((self.evidence_quality.get('missing_required_evidence') or [])[:3])}."
                    ]
                    if self.evidence_quality.get("missing_required_evidence")
                    else []
                )
                + (self.summary.get("open_questions") or [])
            )[:3],
            "assumptions": dedupe_strings(self.summary.get("assumptions") or [])[:4],
            "omitted_context": self._omitted_context(),
            **self.local_ai_metrics,
        }

    def _omitted_context(self):
        return {
            "discovered_files": len(self.discovered),
            "selected_evidence_items": len(self.evidence_items),
            "local_summary_model_used": bool(self.use_local_summary),
            "analysis_depth": self.analysis_depth,
            "graph_answers": len(self.graph_result.get("answers") or []),
            "graph_suggested_files": self.graph_suggested_paths[:5],
            "graph_warnings": (self.graph_result.get("warnings") or [])[:2],
            "graphify": "project_only" if self.graph_allowed and self.graph_result.get("graphs") else "skipped",
            "evidence_quality": self.evidence_quality,
            "evidence_policy": self.policy_summary,
            **self.local_ai_metrics,
        }

    def _finalize_packet(self):
        from .packet import build_codex_packet, build_prompt_compiler_packet, estimate_tokens

        builder = build_prompt_compiler_packet if self.packet_profile == "prompt_compiler" else build_codex_packet
        self.bundle["codex_packet"] = builder(self.normalized_prompt, self.bundle, self.token_budget)
        self.bundle["estimated_tokens"] = estimate_tokens(self.bundle["codex_packet"])
        self._add_token_savings(estimate_tokens)
        self.bundle["enriched_prompt"] = self.bundle["codex_packet"]

    def _add_token_savings(self, estimate_tokens):
        baseline = build_task_candidate_baseline(
            project_root=self.project_root,
            discovered=self.discovered,
            preflight=self.preflight,
            evidence_items=self.evidence_items,
            git_status=self.git_status,
            git_diff_summary=self.git_diff_summary,
            model_profile=self.token_model_profile,
            packet_tokens=self.bundle["estimated_tokens"],
        )
        reduction = build_estimated_context_reduction(
            packet=self.bundle["codex_packet"],
            budget=self.token_budget,
            budget_tokens=TOKEN_BUDGETS[self.token_budget],
            model_profile=self.token_model_profile,
            task_candidate_baseline=baseline,
        )
        savings = build_operation_savings(
            packet=self.bundle["codex_packet"],
            project_root=self.project_root,
            git_status=self.git_status,
            evidence_items=self.evidence_items,
            budget=self.token_budget,
            budget_tokens=TOKEN_BUDGETS[self.token_budget],
            model_profile=self.token_model_profile,
        )
        self.bundle["estimated_context_reduction"] = reduction
        self.bundle["operation_savings"] = savings
        self.bundle["token_savings"] = build_token_savings(
            packet=self.bundle["codex_packet"],
            budget=self.token_budget,
            budget_tokens=TOKEN_BUDGETS[self.token_budget],
            model_profile=self.token_model_profile,
            estimated_context_reduction=reduction,
            operation_savings=savings,
        )

    def _write_audit(self):
        from .packet import estimate_tokens

        next_calls = ["Use packet first.", "Call soma_code_context for 1 focused missing area."]
        missing = build_missing_evidence(
            original_prompt=self.user_prompt,
            normalized_prompt=self.normalized_prompt,
            project_root=self.project_root,
            discovered=self.discovered,
            repo_index=self.repo_index,
            evidence_items=self.evidence_items,
            preflight=self.preflight,
            evidence_quality=self.evidence_quality,
            graph_result=self.graph_result,
            analysis_stages=self.analysis_stages,
            next_calls=next_calls,
        )
        status = "ok" if self.evidence_quality["status"] == "ok" and missing["status"] == "ok" else "degraded"
        report = write_prepare_audit(
            build_prepare_audit(
                context=self.audit_context,
                status=status,
                project_root=self.project_root,
                project_type=self.project_type,
                original_prompt=self.user_prompt,
                normalized_prompt=self.normalized_prompt,
                packet=self.bundle["codex_packet"],
                estimated_tokens=self.bundle.get("estimated_tokens"),
                evidence_items=self.evidence_items,
                missing_evidence=missing,
                evidence_quality=self.evidence_quality,
                tool_calls_expected=next_calls,
                language_optimization=self.language_optimization,
            )
        )
        self.bundle["audit"] = compact_response_audit(report)
        operation_savings = finalize_operation_savings_response_tokens(
            self.bundle["operation_savings"], estimate_tokens(json.dumps(self.bundle))
        )
        self.bundle["operation_savings"] = operation_savings
        self.bundle["token_savings"] = build_token_savings(
            packet=self.bundle["codex_packet"],
            budget=self.token_budget,
            budget_tokens=TOKEN_BUDGETS[self.token_budget],
            model_profile=self.token_model_profile,
            estimated_context_reduction=self.bundle["estimated_context_reduction"],
            operation_savings=operation_savings,
        )
