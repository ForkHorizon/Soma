# #0026 AVAudioEngine aborts when ASRManager forces a 48 kHz client format onto 44.1 kHz microphone hardware.

- 2026-07-14T17:38:49Z `issue`: AVAudioEngine aborts when ASRManager forces a 48 kHz client format onto 44.1 kHz microphone hardware. [Soma/ViewModels/ASRManager.swift]
- 2026-07-14T17:38:49Z `attempt`: Added termination cleanup so closing Soma cancels active global recording and removes the event tap. [Soma/GlobalVoiceController.swift] (worked)
- 2026-07-14T17:39:41Z `attempt`: Removed the forced mixer format and now creates the converter from the tap buffer's live hardware format; the Debug build passes, but the 44.1 kHz device still needs a recording smoke test. [Soma/ViewModels/ASRManager.swift] (partial)
