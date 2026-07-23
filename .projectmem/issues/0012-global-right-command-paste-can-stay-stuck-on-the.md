# #0012 Global Right Command paste can stay stuck on the Accessibility prompt after the user grants access.

- 2026-07-08T18:36:33Z `issue`: Global Right Command paste can stay stuck on the Accessibility prompt after the user grants access. [Soma/GlobalVoiceController.swift]
- 2026-07-08T18:37:22Z `attempt`: Added a pending-permission retry loop so Global Right Command paste starts once Accessibility trust appears. [Soma/GlobalVoiceController.swift] (partial)
- 2026-07-08T18:38:16Z `attempt`: xcodebuild succeeded after the Accessibility retry-loop change; no compile regressions. [Soma/GlobalVoiceController.swift] (worked)
- 2026-07-08T18:38:22Z `fix`: Global Right Command paste now retries Accessibility trust while permission is pending, so granting access can start the listener without another toggle. [Soma/GlobalVoiceController.swift]
