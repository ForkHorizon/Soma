# #0023 Soma asks for the login keychain password on every relaunch when reading the voice-server token.

- 2026-07-09T13:48:46Z `issue`: Soma asks for the login keychain password on every relaunch when reading the voice-server token. [Soma/VoiceServerTokenStore.swift]
- 2026-07-09T13:53:11Z `attempt`: Changed VoiceServerTokenStore to read/write a local no-prompt token first, with Keychain only as non-interactive best-effort mirror; seeded existing token to app defaults. [Soma/VoiceServerTokenStore.swift] (worked)
- 2026-07-09T13:53:16Z `fix`: Soma no longer prompts for the Keychain voice-server token on relaunch; rebuilt app runs and defaults-backed server health check returns 200. [Soma/VoiceServerTokenStore.swift]
