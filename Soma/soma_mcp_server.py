#!/usr/bin/env python3
"""
Soma MCP Server Stub
This script acts as a backwards-compatible entry point for existing AI clients.
The core server logic has been moved to mcp/server.py.
"""
import sys
from pathlib import Path

# Add the current directory to sys.path so 'mcp' can be imported
sys.path.insert(0, str(Path(__file__).parent))



if __name__ == "__main__":
    import gateway.server
    gateway.server.main()
