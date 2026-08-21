# #0009 Project tool chooser shows Install for tools already installed in the selected project instead of an Installed state.

- 2026-07-08T09:37:25Z `issue`: Project tool chooser shows Install for tools already installed in the selected project instead of an Installed state. [Soma/ContentView.swift]
- 2026-07-08T09:38:23Z `attempt`: passed selected-project installed tool ids into Add Tool chooser and rendered Installed text instead of Install button for already installed tools; xcodebuild passed [Soma/ContentView.swift] (worked)
- 2026-07-08T09:38:26Z `fix`: Project Add Tool chooser now marks selected-project tools as Installed and only shows Install for missing supported tools. [Soma/ContentView.swift]
