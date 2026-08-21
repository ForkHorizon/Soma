import asyncio
import json
import os
import subprocess
import sys
from pathlib import Path


async def main():
    soma_script = Path(__file__).parent.parent / "Soma" / "soma_mcp_server.py"
    if not soma_script.exists():
        print(f"FAIL: {soma_script} not found")
        sys.exit(1)

    project_root = str(Path(__file__).parent.parent)

    print("--- Starting Soma MCP stdio server ---")
    proc = await asyncio.create_subprocess_exec(
        sys.executable,
        str(soma_script),
        "--project-root",
        project_root,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env={**os.environ, "SOMA_PROJECT_ROOT": project_root},
    )

    if not proc.stdin or not proc.stdout:
        print("FAIL: Failed to open pipes")
        sys.exit(1)

    async def send_request(method, params=None, id=1):
        req = {"jsonrpc": "2.0", "id": id, "method": method, "params": params or {}}
        data = json.dumps(req)
        msg = data + "\n"
        print(f"-> {method}")
        proc.stdin.write(msg.encode())
        await proc.stdin.drain()

    async def read_response():
        line = await proc.stdout.readline()
        if not line:
            return None
        return json.loads(line.decode().strip())

    # 1. Initialize
    await send_request(
        "initialize",
        {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "e2e_test", "version": "1.0"}},
        id=1,
    )

    resp = await read_response()
    if not resp or resp.get("id") != 1:
        print("FAIL: Initialization failed")
        sys.exit(1)
    print(
        f"<- initialize OK. Server info: {resp['result']['serverInfo']['name']} v{resp['result']['serverInfo']['version']}"
    )

    # 2. tools/list (5.2 Schema Compliance)
    await send_request("tools/list", id=2)
    resp = await read_response()
    if not resp or resp.get("id") != 2:
        print("FAIL: tools/list failed")
        sys.exit(1)
    tools = resp["result"]["tools"]
    print(f"<- tools/list OK. Found {len(tools)} tools.")

    # Verify exact 12 tools and their schemas
    expected_tools = {
        "soma_prepare_context",
        "soma_get_map",
        "soma_ask",
        "soma_code_context",
        "soma_scene",
        "soma_inspect",
        "soma_debug",
        "soma_review",
        "soma_delta",
        "soma_apply",
        "soma_execute",
        "soma_remember",
    }
    found_tools = {t["name"] for t in tools}
    if found_tools != expected_tools:
        print(f"FAIL: Missing expected tools. Found: {found_tools}")
        sys.exit(1)
    print("<- All 12 required tools present.")

    for t in tools:
        if "inputSchema" not in t:
            print(f"FAIL: Tool {t['name']} missing inputSchema")
            sys.exit(1)
        if not t.get("signature"):
            print(f"FAIL: Tool {t['name']} missing signature")
            sys.exit(1)

    # 3. ping (5.3 MCP protocol compliance)
    await send_request("ping", id=3)
    resp = await read_response()
    if not resp or resp.get("id") != 3:
        print("FAIL: ping failed")
        sys.exit(1)
    print("<- ping OK.")

    # 4. tools/call (soma_ask)
    await send_request("tools/call", {"name": "soma_ask", "arguments": {"question": "What tools are available?"}}, id=4)
    resp = await read_response()
    if not resp or resp.get("id") != 4:
        print("FAIL: tools/call soma_ask failed")
        sys.exit(1)

    content = resp["result"]["content"][0]["text"]
    obj = json.loads(content)
    print(f"<- tools/call soma_ask OK. Status: {obj.get('status')}")

    proc.terminate()
    await proc.wait()
    print("\nSUCCESS: End-to-end MCP verification passed.")


if __name__ == "__main__":
    asyncio.run(main())
