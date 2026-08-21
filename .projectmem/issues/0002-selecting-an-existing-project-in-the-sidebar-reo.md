# #0002 Selecting an existing project in the sidebar reorders recentProjectRoots and moves the clicked project to the top.

- 2026-07-07T23:40:55Z `issue`: Selecting an existing project in the sidebar reorders recentProjectRoots and moves the clicked project to the top. [Soma/ViewModels/SomaViewModel+Project.swift]
- 2026-07-07T23:41:41Z `attempt`: Changed project root selection/hydration to preserve existing recentProjectRoots order and append only newly added roots. [Soma/ViewModels/SomaViewModel+Project.swift] (worked)
- 2026-07-07T23:41:47Z `fix`: Project clicks no longer move items to the top; existing sidebar order is preserved and macOS build passes. [Soma/ViewModels/SomaViewModel+Project.swift]
