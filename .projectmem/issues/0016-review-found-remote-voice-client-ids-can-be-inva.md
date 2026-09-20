# #0016 Review found remote voice client IDs can be invalid HTTP header values and broker backend log handles can leak.

- 2026-07-09T09:05:37Z `issue`: Review found remote voice client IDs can be invalid HTTP header values and broker backend log handles can leak. [Soma/ViewModels/ASRManager.swift; Soma/voice_server.py]
- 2026-07-09T09:07:22Z `attempt`: generated UUID-only voice server client IDs and scoped backend log file handle with context manager [Soma/ViewModels/ASRManager.swift; Soma/voice_server.py] (worked)
- 2026-07-09T09:07:28Z `fix`: remote client IDs are now header-safe UUIDs and backend log handles close after process spawn; Python tests, diff check, and clean Xcode build pass [Soma/ViewModels/ASRManager.swift; Soma/voice_server.py]
