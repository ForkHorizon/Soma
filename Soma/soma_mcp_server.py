#!/usr/bin/env python3
"""
Soma MCP Server Stub
This script acts as a backwards-compatible entry point for existing AI clients.
The core server logic has been moved to mcp/server.py.
"""

import sys
from pathlib import Path

# Add the current directory to sys.path so bundled modules can be imported.
server_root = Path(__file__).parent
sys.path.insert(0, str(server_root))

from soma_import_bootstrap import install_soma_gateway_namespace

install_soma_gateway_namespace(server_root)


if __name__ == "__main__":
    import gateway.server

    gateway.server.main()
