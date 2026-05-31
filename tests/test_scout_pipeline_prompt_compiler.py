from scout_pipeline_test_helpers import *


class ScoutPipelinePromptCompilerTests(ScoutPipelineTestCase):
    def test_candidate_filter_normalizes_string_notes(self):
        response = {"message": {"content": "{\"selected_ids\":[1],\"notes\":\"picked manifest\"}"}}
        evidence = [
            {"path": "/repo/A.cs", "kind": "source", "reason": "", "preview": "", "symbols": []},
            {"path": "/repo/AndroidManifest.xml", "kind": "config", "reason": "", "preview": "", "symbols": []},
        ]
        preflight = {"packet_mode": "review", "terms": ["apk"], "expanded_terms": ["apk", "android", "icon"]}
        with patch("scout_pipeline.query_ollama_model", new=AsyncMock(return_value=response)):
            _, stage = asyncio.run(
                scout_pipeline.filter_candidates_with_model(
                    "Investigate apk icon issue.",
                    preflight,
                    evidence,
                    max_items=1,
                )
            )

        self.assertEqual(stage["notes"], ["picked manifest"])

    def test_unity_apk_icon_prompt_includes_icon_and_manifest_context(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Assets" / "Plugins" / "Android").mkdir(parents=True)
            (root / "Assets" / "Visual" / "Sprites" / "Icon").mkdir(parents=True)
            (root / "ProjectSettings").mkdir()
            (root / "ProjectSettings" / "ProjectSettings.asset").write_text(
                "PlayerSettings:\n"
                "  companyName: test\n"
                "  platformSettings:\n"
                "  - serializedVersion: 3\n"
                "    m_BuildTarget: Android\n"
                "    m_Icons:\n"
                "    - m_Textures:\n"
                "      - {fileID: 2800000, guid: icon-guid, type: 3}\n"
            )
            (root / "ProjectSettings" / "GraphicsSettings.asset").write_text(
                "GraphicsSettings:\n  m_CustomRenderPipeline: {fileID: 0}\n"
            )
            (root / "Assets" / "Plugins" / "Android" / "AndroidManifest.xml").write_text(
                "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\">\n"
                "  <application android:icon=\"@mipmap/app_icon\" />\n"
                "</manifest>\n"
            )
            (root / "Assets" / "Visual" / "Sprites" / "Icon" / "Icon.png.meta").write_text(
                "fileFormatVersion: 2\n"
                "guid: icon-guid\n"
                "TextureImporter:\n"
                "  textureType: 8\n"
                "  platformSettings:\n"
                "  - name: Android\n"
                "    overridden: 1\n"
            )
            bundle = self.run_gather(
                "Investigate issue where apk icon becomes incorrect.",
                root,
                "balanced",
                False,
            )

        paths = [item["path"].replace("\\", "/") for item in bundle["evidence_items"]]
        self.assertTrue(any(path.endswith("/ProjectSettings/ProjectSettings.asset") for path in paths))
        self.assertTrue(any(path.endswith("/Assets/Plugins/Android/AndroidManifest.xml") for path in paths))
        self.assertTrue(any(path.endswith("/Assets/Visual/Sprites/Icon/Icon.png.meta") for path in paths))
        self.assertIn("m_Icons", bundle["codex_packet"])
        self.assertIn("m_BuildTarget: Android", bundle["codex_packet"])

    def test_prompt_compiler_profile_omits_generic_git_and_metrics_sections(self):
        tmp, root = self.make_repo()
        with tmp:
            bundle = self.run_gather(
                "check relay diff",
                root,
                "balanced",
                False,
                "deterministic",
                "prompt_compiler",
            )

        packet = bundle["codex_packet"]
        self.assertIn("Focused Evidence:", packet)
        self.assertNotIn("Git status:", packet)
        self.assertNotIn("Git diff summary:", packet)
        self.assertNotIn("Token budget:", packet)
        self.assertNotIn("Omitted context:", packet)
        self.assertNotIn("Graph context (from Graphify):", packet)


if __name__ == '__main__':
    unittest.main()
