# #0018 M1 live voice-server smoke could not bind port 8765 because another local process already used it.

- 2026-07-09T10:41:26Z `issue`: M1 live voice-server smoke could not bind port 8765 because another local process already used it. [~/soma-voice-server-test/Soma/voice_server.py]
- 2026-07-09T10:42:00Z `attempt`: Started M1 smoke broker on a free ephemeral localhost port instead of occupied 8765. [~/soma-voice-server-test] (worked)
- 2026-07-09T10:42:06Z `fix`: Live smoke uses a free localhost port on the M1 and broker health succeeds without disturbing the existing CI Scope Broker on 8765. [~/soma-voice-server-test]
