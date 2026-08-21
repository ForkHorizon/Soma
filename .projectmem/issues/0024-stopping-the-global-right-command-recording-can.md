# #0024 Stopping the global Right Command recording can leave Soma visibly stuck in the Recording state.

- 2026-07-10T21:37:39Z `issue`: Stopping the global Right Command recording can leave Soma visibly stuck in the Recording state. [Soma/GlobalVoiceController.swift]
- 2026-07-10T21:38:04Z `attempt`: Made global listener shutdown cancel any active recording before removing the event tap. [Soma/GlobalVoiceController.swift] (partial)
- 2026-07-10T21:40:27Z `attempt`: Rebuilt Soma, terminated the stale Xcode-debug recording process, and relaunched the corrected Debug app. [Soma/GlobalVoiceController.swift] (worked)
- 2026-07-14T17:39:41Z `attempt`: Added app-termination cleanup for the global event tap and active ASR recording; normal launch and quit leaves no Soma or debugserver process. [Soma/SomaApp.swift] (worked)
- 2026-07-14T17:39:41Z `fix`: Normal app termination now cancels global recording and disables the event tap before Soma exits. [Soma/SomaApp.swift]
