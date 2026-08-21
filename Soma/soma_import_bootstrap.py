"""Import bootstrap for Soma's bundled namespace-style Python modules."""

from __future__ import annotations

import importlib
import importlib.machinery
import sys
import types
from pathlib import Path


def install_soma_gateway_namespace(base_dir: str | Path | None = None) -> None:
    """Force `gateway.*` imports to resolve to Soma's bundled gateway.

    Soma ships Python gateway files as app resources without package
    `__init__.py` files. In developer machines that also have Hermes Agent
    installed, Python can otherwise resolve `import gateway` to Hermes' gateway
    package before Soma's namespace package. This lightweight namespace module
    keeps Soma's MCP entrypoints self-contained without adding `__init__.py`
    resources that collide in the Xcode app bundle.
    """
    root = Path(base_dir) if base_dir is not None else Path(__file__).resolve().parent
    root = root.resolve()
    root_path = str(root)
    if root_path not in sys.path:
        sys.path.insert(0, root_path)

    gateway_path = str(root / "gateway")
    gateway = types.ModuleType("gateway")
    gateway.__path__ = [gateway_path]
    gateway.__package__ = "gateway"
    gateway.__spec__ = importlib.machinery.ModuleSpec("gateway", loader=None, is_package=True)
    gateway.__spec__.submodule_search_locations = [gateway_path]
    sys.modules["gateway"] = gateway

    tools_path = str(root / "gateway" / "tools")
    tools = types.ModuleType("gateway.tools")
    tools.__path__ = [tools_path]
    tools.__package__ = "gateway.tools"
    tools.__spec__ = importlib.machinery.ModuleSpec("gateway.tools", loader=None, is_package=True)
    tools.__spec__.submodule_search_locations = [tools_path]
    sys.modules["gateway.tools"] = tools
    setattr(gateway, "tools", tools)


def attach_common_gateway_modules() -> None:
    """Attach commonly accessed submodules as gateway attributes."""
    gateway = sys.modules.get("gateway")
    if gateway is None:
        install_soma_gateway_namespace()
        gateway = sys.modules["gateway"]
    for name in ("core", "server", "tool_registry", "jsonrpc", "client_config"):
        module = importlib.import_module(f"gateway.{name}")
        setattr(gateway, name, module)
    tools = sys.modules.get("gateway.tools")
    if tools is not None:
        for name in ("context", "nexus", "query", "memory"):
            module = importlib.import_module(f"gateway.tools.{name}")
            setattr(tools, name, module)
