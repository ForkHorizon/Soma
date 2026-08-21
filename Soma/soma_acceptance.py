import asyncio
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path


async def run_acceptance(project_root: str) -> dict:
    soma_script = Path(__file__).parent / "soma_mcp_server.py"
    if not soma_script.exists():
        return {"status": "error", "message": f"{soma_script} not found"}

    print("--- Starting Soma Acceptance Suite ---")

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
        return {"status": "error", "message": "Failed to open pipes"}

    report = {
        "timestamp": datetime.now().isoformat(),
        "project_root": project_root,
        "stages": [],
        "errors": 0,
        "total_time_ms": 0,
        "status": "pending",
    }

    start_time = time.time()

    async def send_request(method, params=None, id=1):
        req = {"jsonrpc": "2.0", "id": id, "method": method, "params": params or {}}
        data = json.dumps(req)
        msg = data + "\n"
        proc.stdin.write(msg.encode())
        await proc.stdin.drain()

    async def read_response():
        line = await proc.stdout.readline()
        if not line:
            return None
        return json.loads(line.decode().strip())

    async def run_stage(name, method, params=None, id=1, validator=None):
        stage_start = time.time()
        print(f"-> {name} ({method})")
        await send_request(method, params, id)
        resp = await read_response()

        duration = int((time.time() - stage_start) * 1000)

        stage_res = {"name": name, "method": method, "duration_ms": duration, "success": False, "error": None}

        if not resp:
            stage_res["error"] = "No response"
        elif "error" in resp:
            stage_res["error"] = resp["error"].get("message", "Unknown error")
        elif resp.get("id") != id:
            stage_res["error"] = f"ID mismatch: {resp.get('id')} != {id}"
        elif validator:
            try:
                validator(resp["result"])
                stage_res["success"] = True
            except Exception as e:
                stage_res["error"] = f"Validation failed: {e}"
        else:
            stage_res["success"] = True

        if stage_res["success"]:
            print(f"<- OK ({duration}ms)")
        else:
            print(f"<- FAIL: {stage_res['error']} ({duration}ms)")
            report["errors"] += 1

        report["stages"].append(stage_res)
        return stage_res["success"]

    # 1. Initialize
    def val_init(res):
        assert "serverInfo" in res, "Missing serverInfo"

    await run_stage(
        "Initialization",
        "initialize",
        {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "soma_acceptance", "version": "1.0"},
        },
        id=1,
        validator=val_init,
    )

    # 2. tools/list
    def val_tools(res):
        tools = res.get("tools", [])
        assert len(tools) == 12, f"Expected 12 tools, got {len(tools)}"
        for t in tools:
            assert "inputSchema" in t, f"Tool {t['name']} missing schema"

    await run_stage("Tool Discovery", "tools/list", id=2, validator=val_tools)

    # 3. get_map
    def val_map(res):
        obj = json.loads(res["content"][0]["text"])
        assert obj["status"] in ("ok", "degraded"), f"Bad map status: {obj['status']}"

    await run_stage("Project Map", "tools/call", {"name": "soma_get_map", "arguments": {}}, id=3, validator=val_map)

    # 4. ask
    def val_ask(res):
        obj = json.loads(res["content"][0]["text"])
        assert obj["status"] in ("ok", "degraded"), f"Bad ask status: {obj['status']}"

    await run_stage(
        "Graph Query",
        "tools/call",
        {"name": "soma_ask", "arguments": {"question": "How does SomaMCPCoordinator work?"}},
        id=4,
        validator=val_ask,
    )

    proc.terminate()
    await proc.wait()

    report["total_time_ms"] = int((time.time() - start_time) * 1000)
    report["status"] = "pass" if report["errors"] == 0 else "fail"

    # Save report
    out_dir = Path.home() / ".soma" / "acceptance"
    out_dir.mkdir(parents=True, exist_ok=True)
    date_str = datetime.now().strftime("%Y%m%d")
    out_file = out_dir / f"e2e_{date_str}.json"
    out_file.write_text(json.dumps(report, indent=2))

    # Save "latest.json" for UI
    (out_dir / "latest.json").write_text(json.dumps(report, indent=2))

    print(f"\nAcceptance {report['status'].upper()} in {report['total_time_ms']}ms. Errors: {report['errors']}")
    print(f"Report saved to {out_file}")

    return report


if __name__ == "__main__":
    project_root = sys.argv[1] if len(sys.argv) > 1 else str(Path(__file__).parent.parent)
    report = asyncio.run(run_acceptance(project_root))
    sys.exit(0 if report["status"] == "pass" else 1)
