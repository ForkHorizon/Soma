#!/usr/bin/env python3
"""Stress-run Rus to Prompt with adversarial prompts."""
from __future__ import annotations

import sys as _sys

_sys.dont_write_bytecode = True

from rus_to_prompt_stress_confidence import *  # noqa: F401,F403
from rus_to_prompt_stress_models import *  # noqa: F401,F403
from rus_to_prompt_stress_providers import *  # noqa: F401,F403
from rus_to_prompt_stress_results import *  # noqa: F401,F403
from rus_to_prompt_stress_runner import main  # noqa: F401


if __name__ == "__main__":
    _sys.modules.setdefault("rus_to_prompt_stress", _sys.modules[__name__])
    raise SystemExit(main())
