# Soma Voice Server

Soma Voice Server runs ASR on the M1 MacBook and lets other Macs use it over
private Tailscale HTTPS. Soma.app still owns recording, voice modes, translation, prompt
polishing, and paste-back behavior.

## Run on the M1 Mac

The server expects per-engine venvs under one ASR root:

```sh
~/soma-asr-bench/
  venv-whisper/
  venv-gigaam/
  asr-models/
```

Start the broker for a temporary local-only test:

```sh
export SOMA_VOICE_TOKEN="$(uuidgen)"
python3 /path/to/Soma/Soma/voice_server.py \
  --host 127.0.0.1 \
  --port 8765 \
  --asr-root ~/soma-asr-bench \
  --idle-seconds 600
```

The broker refuses to start without `SOMA_VOICE_TOKEN`; use
`--allow-unauthenticated-local` only for local development on `127.0.0.1`.

For production, keep the Python server on loopback and publish it through
Tailscale Serve. This gives the app a normal HTTPS URL while keeping the ASR
port private to the M1:

```sh
# Enable HTTPS certificates/MagicDNS in the tailnet once, then run on the M1:
tailscale serve --https=443 --bg http://127.0.0.1:18765
```

Use the resulting `https://<machine>.<tailnet>.ts.net` URL in Soma. The app
rejects remote HTTP URLs. The bearer token remains required; it is stored in
the macOS Keychain, never in Git/docs or UserDefaults.

## Autolaunch

Install a user LaunchAgent:

```sh
SOMA_VOICE_TOKEN="your-token" python3 /path/to/Soma/Soma/voice_server.py \
  --install-launch-agent \
  --host 127.0.0.1 \
  --port 18765 \
  --asr-root ~/soma-asr-bench \
  --idle-seconds 900
```

Load it:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.daliys.soma.voice-server.plist
launchctl enable gui/$(id -u)/com.daliys.soma.voice-server
launchctl kickstart -k gui/$(id -u)/com.daliys.soma.voice-server
```

Logs:

```sh
tail -f ~/Library/Logs/soma-voice-server.out.log
tail -f ~/Library/Logs/soma-voice-server.err.log
```

The native **Soma Voice Server** monitor reads the port and token from that
LaunchAgent plist; no separate `server.port` or `server.token` files are
needed.

## API

- `GET /v1/health` advertises API version and capabilities.
- `POST /v1/warmup` loads the selected ASR model without creating a transcription job.
- `POST /v1/transcriptions` with raw `audio/wav` preserves the v1 whole-file flow.
- `GET /v1/transcriptions/{job_id}?wait=25` long-polls a whole-file job.
- `POST /v1/sessions` creates a v2 pause-aware recording session.
- `PUT /v1/sessions/{session_id}/chunks/{index}` uploads one complete WAV chunk in order.
- `POST /v1/sessions/{session_id}/finalize` marks the final chunk as submitted.
- `GET /v1/sessions/{session_id}?wait=25` returns the final ordered transcript.
- `DELETE /v1/sessions/{session_id}` cancels queued/active session work.

Every request should include:

```http
Authorization: Bearer <token>
X-Soma-Client-ID: <stable-client-id>
X-Soma-Request-ID: <idempotency-key>
X-Soma-Engine: whisper
```

For a v2 chunk upload, also include a request id derived from the session and
chunk index, plus `X-Soma-Chunk-Reason`, `X-Soma-Overlap-Milliseconds`, and
`X-Soma-Chunk-Duration-Milliseconds`. The server rejects future indexes and
accepts an identical retry for an already-uploaded index.

The server is FIFO and runs one ASR job at a time. This preserves chunk order
within a recording session even when jobs from other clients are interleaved. If
a client loses connection after upload, it can long-poll the same job/session;
if a chunk upload fails before acknowledgement, retry with the same request id.
