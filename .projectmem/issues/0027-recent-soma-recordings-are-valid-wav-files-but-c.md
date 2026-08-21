# #0027 Recent Soma recordings are valid WAV files but contain digital silence, causing Whisper to repeat 'Продолжение следует...'.

- 2026-07-14T20:16:26Z `issue`: Recent Soma recordings are valid WAV files but contain digital silence, causing Whisper to repeat 'Продолжение следует...'. [Soma/ViewModels/ASRManager.swift]
- 2026-07-15T11:46:58Z `attempt`: Reset AVAudioEngine before each capture and reject zero-signal PCM before transcription; Debug build succeeded and a clean app process launched for live microphone validation. [Soma/ViewModels/ASRManager.swift] (partial)
- 2026-07-15T11:52:24Z `attempt`: Replaced the reused AVAudioEngine with a fresh engine for every recording so stale USB/sample-rate routes cannot survive into later captures; Debug build succeeded and fresh app launched. [Soma/ViewModels/ASRManager.swift] (partial)
- 2026-07-15T11:57:07Z `attempt`: Signal guard checked only int16ChannelData, but AVAudioFile processing buffers are Float32; valid microphone audio was falsely rejected. [Soma/ViewModels/ASRManager.swift] (failed)
- 2026-07-15T11:57:44Z `attempt`: Updated signal validation to inspect Float32 processing buffers; the previously rejected WAV has normal audio at -27.2 dB, Debug build passes, and a fresh app launched for final recording validation. [Soma/ViewModels/ASRManager.swift] (partial)
