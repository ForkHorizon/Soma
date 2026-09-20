# #0011 Soma Voice Server review found auth, cancel cleanup, and client token storage issues

- 2026-07-08T17:49:56Z `issue`: Soma Voice Server review found auth, cancel cleanup, and client token storage issues [Soma/voice_server.py; Soma/Views/VoiceToTextView.swift; Soma/ViewModels/ASRManager.swift]
- 2026-07-08T17:55:22Z `attempt`: Required explicit voice server auth mode, cleaned canceled queued jobs, moved client token storage to Keychain, and added regression coverage. [Soma/voice_server.py; Soma/Views/VoiceToTextView.swift; Soma/ViewModels/ASRManager.swift; tests/test_soma_voice_server.py] (worked)
- 2026-07-08T17:55:27Z `fix`: Soma Voice Server review issues fixed: auth cannot silently disable, canceled queued jobs are finalized and cleaned up, and client tokens are stored in Keychain. [Soma/voice_server.py; Soma/VoiceServerTokenStore.swift; Soma/Views/VoiceToTextView.swift; Soma/ViewModels/ASRManager.swift; tests/test_soma_voice_server.py]
