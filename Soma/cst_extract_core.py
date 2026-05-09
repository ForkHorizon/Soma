import libcst as cst
import os

SERVER = "/Users/daliys/Daliys/Swift/Soma/Soma/mcp/server.py"
with open(SERVER, "r") as f:
    module = cst.parse_module(f.read())

TARGETS = [
    "_json", "_safe_text", "_compact_result", "_error_response", "_ok_response",
    "_parse_ports", "NexusState", "NexusClient", "_packet_budget", "_analysis_depth",
    "_evidence_summary", "_append_graph_context", "_enforce_packet_budget", "_safe_nexus_result"
]

class CoreExtractor(cst.CSTTransformer):
    def __init__(self):
        self.extracted = []

    def leave_ClassDef(self, original_node, updated_node):
        if original_node.name.value in TARGETS:
            self.extracted.append(original_node)
            return cst.RemovalSentinel.REMOVE
        return updated_node

    def leave_FunctionDef(self, original_node, updated_node):
        if original_node.name.value in TARGETS:
            self.extracted.append(original_node)
            return cst.RemovalSentinel.REMOVE
        return updated_node
        
    def leave_Assign(self, original_node, updated_node):
        # Extract nexus = NexusClient(), graphify = GraphifyAdapter(), memory_store = MemoryStore()
        if len(original_node.targets) == 1 and isinstance(original_node.targets[0].target, cst.Name):
            name = original_node.targets[0].target.value
            if name in ["nexus", "graphify", "memory_store"]:
                self.extracted.append(original_node)
                return cst.RemovalSentinel.REMOVE
        return updated_node

extractor = CoreExtractor()
module = module.visit(extractor)

imports_code = """import json
import urllib.request
from typing import Any
from pathlib import Path
from mcp.graphify_adapter import GraphifyAdapter
from mcp.memory_store import MemoryStore
from scout_pipeline import DEFAULT_TOKEN_BUDGET, MAX_ERROR_LINES, MAX_EVIDENCE_ITEMS, TOKEN_BUDGETS, _truncate_json, estimate_tokens
MAX_TEXT_FIELD_CHARS = 4000
"""

out_body = list(cst.parse_module(imports_code).body)
out_body.extend(extractor.extracted)

with open("/Users/daliys/Daliys/Swift/Soma/Soma/mcp/core.py", "w") as f:
    f.write(cst.Module(body=out_body).code)

with open(SERVER, "w") as f:
    f.write(module.code)

print("Extracted core.")
