#!/usr/bin/env python3
"""Run pytest-style test modules under plain unittest (no pytest installed).

Collects every module-level `test_` function and TestCase class, runs them,
and exits non-zero on any failure — the property CI and humans rely on.
"""

import argparse
import importlib.util
import sys
import traceback
import unittest
from pathlib import Path


def load(path: Path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    assert spec and spec.loader, f"cannot load {path}"
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args()
    suite = unittest.TestSuite()
    loaded = []
    for path in args.paths:
        module = load(path)
        loaded.append(module)
        for name in sorted(dir(module)):
            if name.startswith("test_"):
                obj = getattr(module, name)
                if isinstance(obj, type) and issubclass(obj, unittest.TestCase):
                    suite.addTests(unittest.TestLoader().loadTestsFromTestCase(obj))
                elif callable(obj):
                    suite.addTest(unittest.FunctionTestCase(obj))
    runner = unittest.TextTestRunner(verbosity=1)
    result = runner.run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
