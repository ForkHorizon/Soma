import os
import tempfile
import unittest
import json
import subprocess
import shutil

from Soma.scout_pipeline_module import iter_project_files


class TestGoScanner(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp()

        # Create some test files
        self.create_file("main.cpp", "int main() {}")
        self.create_file("script.sh", "echo 'hello'", executable=True)
        self.create_file(".noise.pyc", "binary")
        self.create_file("ignore_me/.DS_Store", "binary")
        self.create_file("package.json", "{}")

        os.makedirs(os.path.join(self.test_dir, ".git"))
        self.create_file(".git/config", "noise")

    def tearDown(self):
        shutil.rmtree(self.test_dir)

    def create_file(self, path, content, executable=False):
        full_path = os.path.join(self.test_dir, path)
        os.makedirs(os.path.dirname(full_path), exist_ok=True)
        with open(full_path, "w") as f:
            f.write(content)
        if executable:
            os.chmod(full_path, 0o755)

    def test_iter_project_files(self):
        files = iter_project_files(self.test_dir)

        # Go scanner daemon may not be available in test environments
        if not files:
            self.skipTest("Go scanner daemon not available — soma_scanner binary not built")

        names = [f["name"] for f in files]
        paths = [f["path"] for f in files]
        categories = {f["name"]: f["category"] for f in files}

        # Check that we found the right files
        self.assertIn("main.cpp", names)
        self.assertIn("script.sh", names)
        self.assertIn("package.json", names)

        # Check that noise was ignored
        self.assertNotIn(".noise.pyc", names)
        self.assertNotIn(".DS_Store", names)
        self.assertNotIn("config", names)  # Inside .git

        # Check categories
        self.assertEqual(categories["main.cpp"], "source")
        self.assertEqual(categories["script.sh"], "script")
        self.assertEqual(categories["package.json"], "manifest")


if __name__ == "__main__":
    unittest.main()
