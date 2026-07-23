# #0001 Clicking a project in the Projects sidebar only selects the root and does not open a useful project detail view.

- 2026-07-07T23:27:17Z `issue`: Clicking a project in the Projects sidebar only selects the root and does not open a useful project detail view. [Soma/Views/SidebarView.swift]
- 2026-07-07T23:33:06Z `attempt`: Added a project overview CLI payload, hidden Project route, sidebar navigation, and Swift overview UI using existing memory/client/graph actions. [Soma/ContentView.swift] (worked)
- 2026-07-07T23:33:11Z `fix`: Project sidebar clicks now open a Project Overview with Git, memory, graph, plugin, and AI-client status; verified with Python tests and macOS build. [Soma/Views/SidebarView.swift]
