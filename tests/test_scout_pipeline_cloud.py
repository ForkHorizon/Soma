from scout_pipeline_test_helpers import *


class ScoutPipelineCloudTests(ScoutPipelineTestCase):
    def test_ranker_failure_does_not_block_packet(self):
        tmp, root = self.make_repo()
        with tmp, patch("scout_pipeline.query_ollama_model", new=AsyncMock(return_value={"error": "offline"})):
            bundle = self.run_gather("do we have bugs?", root, "balanced", False, "ranked")

        self.assertEqual(bundle["analysis_depth"], "ranked")
        self.assertTrue(bundle["codex_packet"])
        self.assertEqual(bundle["analysis_stages"][-1]["stage"], "ranker")
        # Status is 'failed' when ranker receives error, 'skipped' when no evidence to rank
        self.assertIn(bundle["analysis_stages"][-1]["status"], {"failed", "skipped"})

    def test_openai_cloud_referee_uses_compact_metadata_only(self):
        response = cloud_referee_response()
        with patch.dict(
            os.environ,
            cloud_referee_env(),
        ), patch(
            "scout_pipeline_module.cloud_referee.urllib.request.urlopen",
            return_value=response,
        ) as urlopen:
            result, stage = asyncio.run(
                scout_pipeline.referee_evidence_with_cloud_model(
                    "Review graph version and changelog.",
                    {"required_evidence": ["changelog", "version"]},
                    {"packet_mode": "review"},
                    compact_referee_evidence(),
                    {"status": "ok"},
                )
            )

        request = urlopen.call_args.args[0]
        body = json.loads(request.data.decode("utf-8"))
        payload = json.loads(body["input"][1]["content"])
        self.assertEqual(body["model"], "gpt-test-referee")
        self.assertEqual(stage["status"], "ok")
        self.assertEqual(result["status"], "degraded")
        self.assertIn("changelog", result["missing_evidence"])
        self.assertNotIn("SECRET_SOURCE_BODY", json.dumps(payload))
        self.assertEqual(payload["selected_evidence"][0]["path"], "/repo/Soma/gateway/graphify_adapter.py")

    def test_cloud_referee_policy_defaults_to_degraded_only(self):
        with patch.dict(
            os.environ,
            {
                "SOMA_CLOUD_REFEREE_PROVIDER": "openai",
                "SOMA_OPENAI_API_KEY": "test-key",
            },
            clear=False,
        ):
            self.assertFalse(scout_pipeline.cloud_referee_should_run({"status": "ok", "plan_alignment_status": "ok"}))
            self.assertTrue(scout_pipeline.cloud_referee_should_run({"status": "degraded", "plan_alignment_status": "ok"}))
            self.assertTrue(scout_pipeline.cloud_referee_should_run({"status": "ok", "missing_required_evidence": ["changelog"]}))

    def test_cloud_referee_can_degrade_packet_without_blocking_generation(self):
        tmp, root = self.make_repo()
        response = FakeHTTPResponse(
            json.dumps(
                {
                    "output_text": json.dumps(
                        {
                            "status": "degraded",
                            "missing_evidence": ["All available changelogs"],
                            "recommended_additions": ["graphify --version"],
                            "warnings": [],
                            "notes": [],
                        }
                    )
                }
            )
        )
        with tmp, patch.dict(
            os.environ,
            {
                "SOMA_CLOUD_REFEREE_PROVIDER": "openai",
                "SOMA_OPENAI_API_KEY": "test-key",
                "SOMA_OPENAI_REFEREE_MODEL": "gpt-test-referee",
                "SOMA_CLOUD_REFEREE_POLICY": "always",
            },
        ), patch(
            "scout_pipeline_module.cloud_referee.urllib.request.urlopen",
            return_value=response,
        ):
            bundle = self.run_gather("Review graph version and all changelogs.", root, "balanced", False)

        self.assertTrue(bundle["codex_packet"])
        self.assertEqual(bundle["status"], "degraded")
        self.assertTrue(any(stage["stage"] == "cloud_referee" and stage["status"] == "ok" for stage in bundle["analysis_stages"]))
        self.assertIn("All available changelogs", bundle["evidence_quality"].get("referee_missing_context", []))

    def test_ollama_query_logs_local_model_usage_without_raw_prompt(self):
        response = FakeHTTPResponse(json.dumps({"message": {"content": "{\"ordered_ids\":[0]}"}}))
        with tempfile.TemporaryDirectory() as log_tmp, patch.object(
            llama.urllib.request, "urlopen", return_value=response
        ), patch.object(
            soma_logger, "SOMA_LOG_DIR", Path(log_tmp)
        ), patch.object(
            soma_logger, "SOMA_SESSION_STATS_FILE", Path(log_tmp) / "session_stats.json"
        ):
            result = asyncio.run(
                llama.query_ollama_model(
                    "gemma4:e4b",
                    [{"role": "user", "content": "SECRET_PROMPT"}],
                    json_mode=True,
                    stage="ranker",
                )
            )
            log_text = "\n".join(path.read_text() for path in Path(log_tmp).glob("soma_*.jsonl"))

        self.assertIn("message", result)
        self.assertIn("local_model_call", log_text)
        self.assertIn('"local_model_stage": "ranker"', log_text)
        self.assertIn('"local_model": "gemma4:e4b"', log_text)
        self.assertNotIn("SECRET_PROMPT", log_text)


if __name__ == "__main__":
    unittest.main()


if __name__ == '__main__':
    unittest.main()
