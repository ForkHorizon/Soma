# #0020 Added voice-server status/settings endpoints plus backend health/configure support; 16 voice-server unittest cases pass.

- 2026-07-09T13:13:24Z `issue`: Added voice-server status/settings endpoints plus backend health/configure support; 16 voice-server unittest cases pass. [Soma/voice_server.py; Soma/voice_asr_backend.py; tests/test_soma_voice_server.py]
- 2026-07-09T13:13:24Z `attempt`: Added voice-server status/settings endpoints plus backend health/configure support; 16 voice-server unittest cases pass. [Soma/voice_server.py; Soma/voice_asr_backend.py; tests/test_soma_voice_server.py] (worked)
- 2026-07-09T13:18:22Z `attempt`: Added separate Soma Voice Server target and app UI; Python tests, diff check, main Soma build, and server app build all pass locally. [Soma.xcodeproj; SomaVoiceServer] (worked)
- 2026-07-09T13:19:09Z `attempt`: Initial M1 app install failed because rsync split the remote app path containing spaces; switching to zipped app transfer. [M1 /Applications/Soma Voice Server.app] (failed)
- 2026-07-09T13:21:03Z `attempt`: Live smoke submitted a test job but the polling shell script failed because it used zsh's read-only status variable. [M1 live smoke] (failed)
- 2026-07-09T13:21:26Z `attempt`: Second live-smoke poll failed from nested shell quoting around Python JSON field access. [M1 live smoke] (failed)
- 2026-07-09T13:23:04Z `attempt`: Final status summary command failed from nested shell quoting around Python f-string JSON keys; rerunning with heredoc-safe quoting. [M1 final smoke] (failed)
- 2026-07-09T13:23:40Z `attempt`: Installed native Soma Voice Server app on the M1, updated remote server files, verified /v1/status, settings patch, app process, queue smoke, and LaunchAgent stop/start. [SomaVoiceServer; M1 /Applications/Soma Voice Server.app] (worked)
- 2026-07-09T13:23:49Z `fix`: Native menu bar Soma Voice Server target, backend status/settings API, tests, local builds, and M1 install smoke are complete. [SomaVoiceServer; Soma/voice_server.py; Soma/voice_asr_backend.py]
