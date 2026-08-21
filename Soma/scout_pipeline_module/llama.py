import json


import re

import shutil
import time


import urllib.request


try:
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client
except ModuleNotFoundError:  # Optional dependency: only needed for live Scout MCP chat.
    ClientSession = None
    StdioServerParameters = None
    stdio_client = None


from .config import *


def extract_tool_calls(content):
    tool_calls = []
    for match in re.finditer(
        '\\{[^{}]*"name"\\s*:\\s*"(?P<name>\\w+)"[^{}]*"(?:parameters|arguments)"\\s*:\\s*(?P<params>\\{[^{}]*\\})[^{}]*\\}',
        content,
        re.DOTALL,
    ):
        try:
            params = json.loads(match.group("params"))
            tool_calls.append({"id": "call_fb", "function": {"name": match.group("name"), "arguments": params}})
        except Exception as exc:
            import sys

            print(f"extract_tool_calls failed: {exc}", file=sys.stderr)
            pass
    if tool_calls:
        return tool_calls
    for block in re.findall("```(?:json)?\\n(.*?)\\n```", content, re.DOTALL):
        try:
            decoded = json.loads(block)
            items = decoded if isinstance(decoded, list) else [decoded]
            for item in items:
                if isinstance(item, dict) and ("name" in item):
                    args = item.get("arguments") or item.get("parameters") or {}
                    tool_calls.append({"id": "call_fb", "function": {"name": item["name"], "arguments": args}})
        except Exception as exc:
            import sys

            print(f"extract_tool_calls failed: {exc}", file=sys.stderr)
            pass
    if tool_calls:
        return tool_calls
    try:
        start = content.find("{")
        end = content.rfind("}")
        if (start != (-1)) and (end > start):
            decoded = json.loads(content[start : (end + 1)])
            if "name" in decoded:
                args = decoded.get("arguments") or decoded.get("parameters") or {}
                if (not args) and ("path" in decoded):
                    args = {"path": decoded["path"]}
                tool_calls.append({"id": "call_fb", "function": {"name": decoded["name"], "arguments": args}})
    except Exception as exc:
        import sys

        print(f"extract_tool_calls failed: {exc}", file=sys.stderr)
        pass
    return tool_calls


def _estimate_local_tokens(text):
    try:
        from token_calculator import estimate_tokens

        return estimate_tokens(text or "", "local")
    except Exception:
        return max(0, len(text or "") // 4)


def _log_local_model_call(
    *,
    model,
    stage,
    status,
    duration_ms,
    messages,
    response_text="",
    error=None,
    json_mode=False,
    num_predict=None,
    tools=None,
    metadata=None,
):
    try:
        from soma_logger import log_mcp_event
        import os

        input_text = json.dumps(messages or [], default=str)
        output_text = response_text or ""
        log_mcp_event(
            event="local_model_call",
            status=status,
            duration_ms=duration_ms,
            input_tokens=_estimate_local_tokens(input_text),
            output_tokens=_estimate_local_tokens(output_text),
            error=error,
            project_root=os.environ.get("SOMA_PROJECT_ROOT"),
            extra={
                "local_model_provider": "ollama",
                "local_model": model,
                "local_model_stage": stage or "ollama_chat",
                "local_model_json_mode": bool(json_mode),
                "local_model_num_predict": num_predict,
                "local_model_tool_count": len(tools or []),
                "local_model_message_count": len(messages or []),
                **(metadata or {}),
            },
        )
    except Exception:
        pass


async def query_ollama(messages, tools=None, timeout=120, stage=None):
    return await query_ollama_model(MODEL, messages, tools=tools, timeout=timeout, stage=stage)


async def query_ollama_model(
    model, messages, tools=None, timeout=120, num_predict=None, json_mode=False, stage=None, metadata=None
):
    data = {
        "model": model,
        "think": False,
        "messages": messages,
        "stream": False,
        "options": {"num_ctx": 4096, "temperature": 0.1},
    }
    if json_mode:
        data["format"] = "json"
    if tools:
        data["tools"] = tools
    if num_predict:
        data["options"]["num_predict"] = num_predict
    req = urllib.request.Request(
        "http://127.0.0.1:11434/api/chat", data=json.dumps(data).encode(), headers={"Content-Type": "application/json"}
    )
    start = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            response_text = response.read().decode()
            decoded = json.loads(response_text)
            status = "error" if isinstance(decoded, dict) and decoded.get("error") else "ok"
            _log_local_model_call(
                model=model,
                stage=stage,
                status=status,
                duration_ms=(time.monotonic() - start) * 1000,
                messages=messages,
                response_text=response_text,
                error=decoded.get("error") if isinstance(decoded, dict) else None,
                json_mode=json_mode,
                num_predict=num_predict,
                tools=tools,
                metadata=metadata,
            )
            return decoded
    except Exception as exc:
        _log_local_model_call(
            model=model,
            stage=stage,
            status="error",
            duration_ms=(time.monotonic() - start) * 1000,
            messages=messages,
            error=str(exc),
            json_mode=json_mode,
            num_predict=num_predict,
            tools=tools,
            metadata=metadata,
        )
        return {"error": str(exc)}


def get_server_params(allowed_dirs=None):
    if StdioServerParameters is None:
        raise RuntimeError("The optional 'mcp' package is required for live Scout MCP chat")
    npx = shutil.which("npx") or "npx"
    return StdioServerParameters(
        command=npx, args=(["-y", "@modelcontextprotocol/server-filesystem"] + (allowed_dirs or CHAT_ALLOWED_DIRS))
    )


async def get_ollama_tools(session):
    response = await session.list_tools()
    return [
        {
            "type": "function",
            "function": {"name": tool.name, "description": tool.description, "parameters": tool.inputSchema},
        }
        for tool in response.tools
    ]


async def run_chat(user_prompt, history):
    from .utils import fix_path

    if ClientSession is None or stdio_client is None:
        print(json.dumps({"error": "MCP Error: optional 'mcp' package is not installed"}))
        return
    system = {"role": "system", "content": CHAT_SYSTEM}
    messages = ([system] + history) + [{"role": "user", "content": user_prompt}]
    try:
        async with stdio_client(get_server_params()) as (read, write):
            async with ClientSession(read, write) as session:
                (await session.initialize())
                tools = await get_ollama_tools(session)
                response = await query_ollama(messages, tools)
                if "error" in response:
                    print(json.dumps(response))
                    return
                message = response.get("message", {})
                content = message.get("content", "")
                tool_calls = message.get("tool_calls", []) or extract_tool_calls(content)
                if tool_calls:
                    messages.append(message)
                    for tool_call in tool_calls:
                        name = tool_call["function"]["name"]
                        args = tool_call["function"]["arguments"]
                        tool_call_id = tool_call.get("id", "call_default")
                        try:
                            if "path" in args:
                                args["path"] = fix_path(args["path"], CHAT_ALLOWED_DIRS)
                            result = await session.call_tool(name, args)
                            output = content_str(result)
                        except Exception as exc:
                            output = f"Error: {exc}"
                        messages.append({"role": "tool", "tool_call_id": tool_call_id, "name": name, "content": output})
                    final = await query_ollama(messages)
                    if "error" in final:
                        print(json.dumps(final))
                    else:
                        print(
                            json.dumps(
                                {"response": final["message"]["content"], "history": (messages + [final["message"]])}
                            )
                        )
                else:
                    print(json.dumps({"response": content, "history": (messages + [message])}))
    except Exception as exc:
        print(json.dumps({"error": f"MCP Error: {exc}"}))


def content_str(tool_result):
    if hasattr(tool_result, "content"):
        return "\n".join((item.text for item in tool_result.content if hasattr(item, "text")))
    return str(tool_result)
