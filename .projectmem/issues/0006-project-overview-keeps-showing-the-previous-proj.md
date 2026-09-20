# #0006 Project Overview keeps showing the previous project's cards while the new selected project's async refresh is still running.

- 2026-07-08T09:07:36Z `issue`: Project Overview keeps showing the previous project's cards while the new selected project's async refresh is still running. [Soma/ContentView.swift]
- 2026-07-08T09:08:46Z `attempt`: Snapshot selected project root during Project Overview refresh/actions, clear stale overview on project switch, and ignore late async responses for old roots. [Soma/ContentView.swift] (worked)
- 2026-07-08T09:08:53Z `fix`: Project Overview now clears stale cards immediately on project switch and only applies helper results for the still-selected project; xcodebuild passes. [Soma/ContentView.swift]
