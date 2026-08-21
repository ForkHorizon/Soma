import libcst as cst
import os
import shutil

SERVER = "/Users/daliys/Daliys/Swift/Soma/Soma/mcp/server.py"

with open(SERVER, "r") as f:
    original_code = f.read()

module = cst.parse_module(original_code)


class ClassExtractor(cst.CSTTransformer):
    def __init__(self, target_names):
        self.target_names = target_names
        self.extracted = []

    def leave_ClassDef(self, original_node, updated_node):
        if original_node.name.value in self.target_names:
            self.extracted.append(original_node)
            return cst.RemovalSentinel.REMOVE
        return updated_node

    def leave_FunctionDef(self, original_node, updated_node):
        if original_node.name.value in self.target_names:
            self.extracted.append(original_node)
            return cst.RemovalSentinel.REMOVE
        return updated_node


def do_extraction(targets, out_file, extra_imports=[]):
    global module
    extractor = ClassExtractor(targets)
    module = module.visit(extractor)

    # Grab all top level imports from the original
    imports = []
    for stmt in module.body:
        if isinstance(stmt, (cst.SimpleStatementLine)) and any(
            isinstance(s, (cst.Import, cst.ImportFrom)) for s in stmt.body
        ):
            imports.append(stmt)

    out_body = []
    out_body.extend(imports)
    for imp in extra_imports:
        out_body.append(cst.parse_module(imp).body[0])

    out_body.extend(extractor.extracted)

    new_module = cst.Module(body=out_body)
    out_path = os.path.join("/Users/daliys/Daliys/Swift/Soma/Soma/mcp", out_file)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as f:
        f.write(new_module.code)


do_extraction(["GraphifyAdapter"], "graphify_adapter.py")
do_extraction(["MemoryStore"], "memory_store.py")

do_extraction(
    ["soma_prepare_context", "soma_get_map", "soma_code_context"],
    "tools/context.py",
    ["from mcp.graphify_adapter import GraphifyAdapter", "from mcp.memory_store import MemoryStore"],
)

do_extraction(
    ["soma_ask", "soma_review", "soma_debug"],
    "tools/query.py",
    ["from mcp.graphify_adapter import GraphifyAdapter", "from mcp.memory_store import MemoryStore"],
)

do_extraction(["soma_scene", "soma_inspect", "soma_apply", "soma_execute", "soma_delta"], "tools/nexus.py")

do_extraction(["soma_remember"], "tools/memory.py", ["from mcp.memory_store import MemoryStore"])

with open(SERVER, "w") as f:
    f.write(module.code)

print("Split completed perfectly using libcst.")
