# #0015 Review found silent remote health checks can still overwrite recording status and stalled uploads can pin voice-server handler threads.

- 2026-07-09T06:51:58Z `issue`: Review found silent remote health checks can still overwrite recording status and stalled uploads can pin voice-server handler threads. [Soma/ViewModels/ASRManager.swift; Soma/voice_server.py]
- 2026-07-09T08:23:41Z `attempt`: guarded silent health-check status writes and added socket upload timeout before queue submission [Soma/ViewModels/ASRManager.swift; Soma/voice_server.py; tests/test_soma_voice_server.py] (worked)
- 2026-07-09T08:23:45Z `fix`: silent remote health checks no longer overwrite recording status; stalled uploads return retryable 408 before queueing [Soma/ViewModels/ASRManager.swift; Soma/voice_server.py; tests/test_soma_voice_server.py]
