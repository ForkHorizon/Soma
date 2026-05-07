#!/usr/bin/env python3
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from scout_pipeline_module import *

if __name__ == "__main__":
    import argparse, asyncio, json
    parser = argparse.ArgumentParser()
    parser.add_argument("prompt")
    parser.add_argument("history", nargs="?", default="[]")
    parser.add_argument("--mode", default="chat", choices=["chat", "gather"])
    parser.add_argument("--project-root", default="")
    parser.add_argument("--recent-roots-json", default="[]")
    parser.add_argument("--token-budget", default=DEFAULT_TOKEN_BUDGET, choices=sorted(TOKEN_BUDGETS.keys()))
    parser.add_argument("--use-local-summary", action="store_true")
    parser.add_argument("--analysis-depth", default="deterministic", choices=sorted(ANALYSIS_DEPTHS))
    args = parser.parse_args()

    if args.mode == "gather": asyncio.run(run_gather(args.prompt, args.project_root, args.recent_roots_json, args.token_budget, args.use_local_summary, args.analysis_depth))
    else:
        history = []
        try: history = json.loads(args.history)
        except: pass
        asyncio.run(run_chat(args.prompt, history))
