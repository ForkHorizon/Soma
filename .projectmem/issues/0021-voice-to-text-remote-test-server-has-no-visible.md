# #0021 Voice to Text remote Test Server has no visible result and recordings list overwhelms the page.

- 2026-07-09T13:33:14Z `issue`: Voice to Text remote Test Server has no visible result and recordings list overwhelms the page. [Soma/Views/VoiceToTextView.swift]
- 2026-07-09T13:35:20Z `attempt`: Added explicit remote server connection state, visible Voice to Text status row, and collapsible older recordings list. [Soma/Views/VoiceToTextView.swift] (partial)
- 2026-07-09T13:36:19Z `attempt`: Fixed recordings computed property syntax after the first build failure and rebuilt the main Soma app successfully. [Soma/Views/VoiceToTextView.swift] (worked)
- 2026-07-09T13:36:28Z `fix`: Voice to Text now shows explicit remote server online/offline state and collapses older recordings after the newest five; main app build passes. [Soma/Views/VoiceToTextView.swift]
