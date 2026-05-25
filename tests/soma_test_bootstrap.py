"""Test import helpers for Soma's bundled Python modules."""
from __future__ import annotations

import importlib
import importlib.machinery
import sys
import types
from pathlib import Path


def install_soma_imports() -> None:
    """Ensure tests import this repo's bundled gateway modules.

    The developer environment may also have Hermes Agent installed, which exposes
    a top-level `gateway` package. Soma's gateway is bundled as app resources
    without `__init__.py` files, so create a lightweight namespace package for
    tests before importing `gateway.*`.
    """
    repo_root = Path(__file__).resolve().parents[1]
    soma_root = repo_root / "Soma"
    soma_path = str(soma_root)
    if soma_path not in sys.path:
        sys.path.insert(0, soma_path)

    gateway_path = str(soma_root / "gateway")
    gateway = sys.modules.get("gateway")
    if gateway is None or not str(getattr(gateway, "__file__", "")).startswith(gateway_path):
        gateway = types.ModuleType("gateway")
        gateway.__path__ = [gateway_path]
        gateway.__package__ = "gateway"
        gateway.__spec__ = importlib.machinery.ModuleSpec("gateway", loader=None, is_package=True)
        gateway.__spec__.submodule_search_locations = [gateway_path]
        sys.modules["gateway"] = gateway

    # Preload commonly patched submodules so `gateway.core` style attribute
    # access works even though Soma's bundled gateway is a namespace package.
    for name in ("core", "server", "tool_registry", "jsonrpc", "client_config"):
        module = importlib.import_module(f"gateway.{name}")
        setattr(gateway, name, module)

    tools_path = str(soma_root / "gateway" / "tools")
    tools = sys.modules.get("gateway.tools")
    if tools is None:
        tools = types.ModuleType("gateway.tools")
        tools.__path__ = [tools_path]
        tools.__package__ = "gateway.tools"
        tools.__spec__ = importlib.machinery.ModuleSpec("gateway.tools", loader=None, is_package=True)
        tools.__spec__.submodule_search_locations = [tools_path]
        sys.modules["gateway.tools"] = tools
    setattr(gateway, "tools", tools)

    for name in ("context", "nexus", "query", "memory"):
        module = importlib.import_module(f"gateway.tools.{name}")
        setattr(tools, name, module)
