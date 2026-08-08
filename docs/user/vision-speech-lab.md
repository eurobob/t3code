# Comparing speech recognition in T3 Vision

Speech Lab records one microphone sample and transcribes the exact same audio
with two engines:

- WhisperKit with compressed Large v3 Turbo, running privately on Apple Vision
  Pro.
- A configurable `whisper.cpp` Large v3 Turbo server.

Select **Speech Lab** in the task-list toolbar. The lab opens in its own window.
Wait for WhisperKit to finish downloading and preparing its model,
enter the server's `/inference` address, and select **Record Sample**. Select
**Stop & Compare** when you finish speaking; recording also stops automatically
after 60 seconds.

The window reports model-cache checking, download percentage, Core ML
optimization, and loading as separate stages. The first download is roughly
626 MB; later launches reuse the device cache.

Both transcript cards report end-to-end transcription time. Model download and
preparation are excluded from that time. The comparison uses automatic language
detection, temperature zero, no contextual prompt, and one shared 16 kHz mono
WAV so the input is identical.

WhisperKit keeps audio and transcription on the device. The server copy is sent
to the address shown in Speech Lab. For plain HTTP, use the server's numeric LAN
or Tailscale address; otherwise use an authenticated HTTPS endpoint. The
temporary recording is deleted after both engines finish.
