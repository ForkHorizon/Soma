# #0014 Internet-loss review found partial remote uploads can enqueue corrupt audio and retryable voice-server errors are ignored by the client.

- 2026-07-09T06:09:09Z `issue`: Internet-loss review found partial remote uploads can enqueue corrupt audio and retryable voice-server errors are ignored by the client. [Soma/voice_server.py; Soma/ViewModels/ASRManager.swift]
- 2026-07-09T06:17:46Z `attempt`: Rejected short Content-Length uploads before queueing, decoded remote error code/retryable on the client, and resubmitted once when polling finds a lost/retryable job. [Soma/voice_server.py; Soma/ViewModels/ASRManager.swift; tests/test_soma_voice_server.py] (worked)
- 2026-07-09T06:17:50Z `fix`: Internet-loss hardening confirmed: incomplete uploads do not queue jobs, retryable server errors drive client retry/resubmit, 58 Python tests pass, diff check passes, and Xcode Debug build passes. [Soma/voice_server.py; Soma/ViewModels/ASRManager.swift; tests/test_soma_voice_server.py]
