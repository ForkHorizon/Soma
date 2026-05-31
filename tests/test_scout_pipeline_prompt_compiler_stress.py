from scout_pipeline_test_helpers import *


class ScoutPipelinePromptCompilerStressTests(ScoutPipelineTestCase):
    def test_prompt_compiler_open_source_review_focuses_unity_package_not_wrapper(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_nexus_unity_fixture(root)
            bundle = self.run_gather(
                "We are preparing Nexus Unity for open source. Root is only a wrapper for testing; analyze weak and strong places before release.",
                root,
                "balanced",
                False,
                "deterministic",
                "prompt_compiler",
                "off",
            )

        packet = bundle["codex_packet"]
        assert_nexus_package_evidence(self, bundle)
        self.assertEqual(bundle["packet_mode"], "review")
        self.assertIn("open-source readiness review", packet)
        self.assertIn("Collection Plan:", packet)
        self.assertIn("Focus:", packet)
        self.assertIn("Assets/NexusUnity/package.json", packet)
        self.assertNotIn("AutoSavedScene.unity", packet)
        self.assertNotIn("ProjectSettings.asset", packet)


if __name__ == '__main__':
    unittest.main()
