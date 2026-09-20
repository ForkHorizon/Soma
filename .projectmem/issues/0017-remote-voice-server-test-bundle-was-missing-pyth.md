# #0017 Remote voice-server test bundle was missing Python support modules needed by soma_test_bootstrap.

- 2026-07-09T10:39:49Z `issue`: Remote voice-server test bundle was missing Python support modules needed by soma_test_bootstrap. [~/soma-voice-server-test/tests/soma_test_bootstrap.py]
- 2026-07-09T10:40:12Z `attempt`: Synced Soma top-level Python support files into the remote voice-server test bundle. [~/soma-voice-server-test/Soma] (partial)
- 2026-07-09T10:40:28Z `attempt`: Remote unit test still failed because system python3 is 3.9 and Soma gateway test bootstrap needs Python 3.10+ syntax. [~/soma-voice-server-test/tests] (failed)
- 2026-07-09T10:40:49Z `attempt`: Ran remote voice-server py_compile and 12 unit tests successfully with the existing Python 3.11 Whisper venv. [~/soma-voice-server-test] (worked)
- 2026-07-09T10:40:55Z `fix`: Remote test bundle now includes needed Python support files and uses the existing Python 3.11 ASR venv, so voice-server unit tests pass on the M1. [~/soma-voice-server-test]
