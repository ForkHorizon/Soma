# #0010 Soma writes always-on memory tool instructions into projects, causing token-heavy projectmem/codebase-memory use on small tasks.

- 2026-07-08T11:55:06Z `issue`: Soma writes always-on memory tool instructions into projects, causing token-heavy projectmem/codebase-memory use on small tasks. [Soma/extension_manager.py]
- 2026-07-08T11:58:22Z `attempt`: changed generated memory docs to light mode and per-tool content, fixed graphify installed id, and covered setup behavior with Python tests [Soma/extension_manager.py; tests/test_soma_mcp_server.py; AGENTS.md] (worked)
- 2026-07-08T11:58:25Z `fix`: Soma now writes light, per-tool memory instructions so new projects do not force token-heavy memory usage for small tasks. [Soma/extension_manager.py; AGENTS.md; tests/test_soma_mcp_server.py]
