# #0007 Project Overview still renders old project cards during the first render after switching projects because the UI reads stale overview state directly.

- 2026-07-08T09:17:05Z `issue`: Project Overview still renders old project cards during the first render after switching projects because the UI reads stale overview state directly. [Soma/ContentView.swift]
- 2026-07-08T09:18:28Z `attempt`: Guarded all Project Overview card rendering through currentOverview and added skeleton placeholders when selected root has no matching payload yet. [Soma/ContentView.swift] (worked)
- 2026-07-08T09:18:37Z `fix`: Project Overview now hides stale project cards behind skeleton placeholders until the selected project's payload arrives; xcodebuild passes. [Soma/ContentView.swift]
