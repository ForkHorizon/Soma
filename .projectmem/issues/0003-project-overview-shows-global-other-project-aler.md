# #0003 Project Overview shows global Other Project Alerts and scans unrelated projects instead of staying scoped to the selected root.

- 2026-07-07T23:43:55Z `issue`: Project Overview shows global Other Project Alerts and scans unrelated projects instead of staying scoped to the selected root. [Soma/ContentView.swift]
- 2026-07-07T23:47:36Z `attempt`: Removed global project alerts/plugins from Project Overview and changed overview/client sync to use only project-local configs for the selected root. [Soma/extension_manager.py] (worked)
- 2026-07-07T23:47:41Z `fix`: Project Overview is now selected-project scoped: no Other Project Alerts, no global plugin card, and project client sync touches only selected local configs. [Soma/ContentView.swift]
