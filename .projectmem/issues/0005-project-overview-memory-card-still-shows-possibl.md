# #0005 Project Overview Memory card still shows possible memory tools as missing rows instead of only installed project tools with an add-tool action.

- 2026-07-08T08:59:10Z `issue`: Project Overview Memory card still shows possible memory tools as missing rows instead of only installed project tools with an add-tool action. [Soma/ContentView.swift]
- 2026-07-08T09:02:58Z `attempt`: Changed Project Overview memory payload/UI to show only selected-project installed tools and moved memory setup into an Add Tool button in the Memory card. [Soma/ContentView.swift] (worked)
- 2026-07-08T09:03:06Z `fix`: Project Overview Memory card now lists only installed tools for the selected project and exposes Add Tool using the existing setup-memory extension path; Python tests and macOS build pass. [Soma/ContentView.swift]
