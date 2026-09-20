# #0008 Project Overview Add Tool runs a fixed memory setup action instead of opening a panel to choose which extension tool to install.

- 2026-07-08T09:22:40Z `issue`: Project Overview Add Tool runs a fixed memory setup action instead of opening a panel to choose which extension tool to install. [Soma/ContentView.swift]
- 2026-07-08T09:34:30Z `attempt`: implemented Add Tool chooser sheet backed by --tool-status-json and per-tool --setup-project-tool actions; verified Python tests and xcodebuild [Soma/ContentView.swift; Soma/extension_manager.py; Soma/gateway/server_cli.py; tests/test_soma_mcp_server.py] (worked)
- 2026-07-08T09:34:34Z `fix`: Add Tool now opens a project tool chooser and installs the selected supported tool with visible progress/result feedback. [Soma/ContentView.swift; Soma/gateway/server_cli.py; Soma/extension_manager.py; tests/test_soma_mcp_server.py]
