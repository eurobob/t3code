# Speech Lab server

The native Vision app's Speech Lab sends one 16 kHz mono PCM WAV to an HTTP
endpoint and compares its result with the same file transcribed by WhisperKit.
The launcher here builds pinned `whisper.cpp` v1.9.2 and downloads the
unquantized 1.5 GiB Large v3 Turbo model. This is the quality-first model that
still has a practical dictation feedback loop on the current CPU-only Ryzen 5
3600 server. Its build and model files stay in the worktree's ignored `.t3`
directory.

Prepare the binary and model without starting a service:

```sh
./apps/vision/speech-lab/start-whisper-server.sh --prepare-only
```

The server has no authentication and binds to localhost by default. To reach it
from a Vision Pro on the same Tailscale network, bind it to this machine's
specific tailnet address:

```sh
T3_SPEECH_LAB_HOST=<server-tailnet-ip> \
  ./apps/vision/speech-lab/start-whisper-server.sh
```

Then enter `http://<server-tailnet-ip>:8085/inference` in Speech Lab. For use
outside a private network, place the endpoint behind an authenticated HTTPS
reverse proxy instead of exposing `whisper-server` directly. The launcher
refuses wildcard addresses for this reason.

Optional settings:

- `T3_SPEECH_LAB_PORT` changes port `8085`.
- `T3_SPEECH_LAB_THREADS` changes the six-thread default chosen for the current
  Ryzen 5 3600 host.
- `T3_SPEECH_LAB_DIR` moves the ignored build and model cache.

This is an experiment runner, not part of the T3 server process or protocol.
The endpoint can later be swapped for another service that accepts the same
multipart fields and returns `{ "text": "..." }`.
