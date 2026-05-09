



import json


import re

import shutil


import urllib.request


from mcp import ClientSession, StdioServerParameters

from mcp.client.stdio import stdio_client


from .config import *


def extract_tool_calls(content):
    tool_calls = []
    for match in re.finditer('\\{[^{}]*"name"\\s*:\\s*"(?P<name>\\w+)"[^{}]*"(?:parameters|arguments)"\\s*:\\s*(?P<params>\\{[^{}]*\\})[^{}]*\\}', content, re.DOTALL):
        try:
            params = json.loads(match.group('params'))
            tool_calls.append({'id': 'call_fb', 'function': {'name': match.group('name'), 'arguments': params}})
        except Exception:
            pass
    if tool_calls:
        return tool_calls
    for block in re.findall('```(?:json)?\\n(.*?)\\n```', content, re.DOTALL):
        try:
            decoded = json.loads(block)
            items = (decoded if isinstance(decoded, list) else [decoded])
            for item in items:
                if (isinstance(item, dict) and ('name' in item)):
                    args = (item.get('arguments') or item.get('parameters') or {})
                    tool_calls.append({'id': 'call_fb', 'function': {'name': item['name'], 'arguments': args}})
        except Exception:
            pass
    if tool_calls:
        return tool_calls
    try:
        start = content.find('{')
        end = content.rfind('}')
        if ((start != (- 1)) and (end > start)):
            decoded = json.loads(content[start:(end + 1)])
            if ('name' in decoded):
                args = (decoded.get('arguments') or decoded.get('parameters') or {})
                if ((not args) and ('path' in decoded)):
                    args = {'path': decoded['path']}
                tool_calls.append({'id': 'call_fb', 'function': {'name': decoded['name'], 'arguments': args}})
    except Exception:
        pass
    return tool_calls


async def query_ollama(messages, tools=None, timeout=120):
    return (await query_ollama_model(MODEL, messages, tools=tools, timeout=timeout))


async def query_ollama_model(model, messages, tools=None, timeout=120, num_predict=None, json_mode=False):
    data = {'model': model, 'think': False, 'messages': messages, 'stream': False, 'options': {'num_ctx': 4096, 'temperature': 0.1}}
    if json_mode:
        data['format'] = 'json'
    if tools:
        data['tools'] = tools
    if num_predict:
        data['options']['num_predict'] = num_predict
    req = urllib.request.Request('http://127.0.0.1:11434/api/chat', data=json.dumps(data).encode(), headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return json.loads(response.read().decode())
    except Exception as exc:
        return {'error': str(exc)}


def get_server_params(allowed_dirs=None):
    npx = (shutil.which('npx') or 'npx')
    return StdioServerParameters(command=npx, args=(['-y', '@modelcontextprotocol/server-filesystem'] + (allowed_dirs or CHAT_ALLOWED_DIRS)))


async def get_ollama_tools(session):
    response = (await session.list_tools())
    return [{'type': 'function', 'function': {'name': tool.name, 'description': tool.description, 'parameters': tool.inputSchema}} for tool in response.tools]


async def run_chat(user_prompt, history):
    from .utils import fix_path
    system = {'role': 'system', 'content': CHAT_SYSTEM}
    messages = (([system] + history) + [{'role': 'user', 'content': user_prompt}])
    try:
        async with stdio_client(get_server_params()) as (read, write):
            async with ClientSession(read, write) as session:
                (await session.initialize())
                tools = (await get_ollama_tools(session))
                response = (await query_ollama(messages, tools))
                if ('error' in response):
                    print(json.dumps(response))
                    return
                message = response.get('message', {})
                content = message.get('content', '')
                tool_calls = (message.get('tool_calls', []) or extract_tool_calls(content))
                if tool_calls:
                    messages.append(message)
                    for tool_call in tool_calls:
                        name = tool_call['function']['name']
                        args = tool_call['function']['arguments']
                        tool_call_id = tool_call.get('id', 'call_default')
                        try:
                            if ('path' in args):
                                args['path'] = fix_path(args['path'], CHAT_ALLOWED_DIRS)
                            result = (await session.call_tool(name, args))
                            output = content_str(result)
                        except Exception as exc:
                            output = f'Error: {exc}'
                        messages.append({'role': 'tool', 'tool_call_id': tool_call_id, 'name': name, 'content': output})
                    final = (await query_ollama(messages))
                    if ('error' in final):
                        print(json.dumps(final))
                    else:
                        print(json.dumps({'response': final['message']['content'], 'history': (messages + [final['message']])}))
                else:
                    print(json.dumps({'response': content, 'history': (messages + [message])}))
    except Exception as exc:
        print(json.dumps({'error': f'MCP Error: {exc}'}))


def content_str(tool_result):
    if hasattr(tool_result, 'content'):
        return '\n'.join((item.text for item in tool_result.content if hasattr(item, 'text')))
    return str(tool_result)
