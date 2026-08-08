# Dictating in T3 Vision

T3 Vision transcribes dictation privately on Apple Vision Pro using WhisperKit
and a compressed Large v3 Turbo model. Audio is not sent to a T3 server or a
third-party transcription service.

Select the microphone in the composer once to start recording and again to
stop. The dictation panel shows partial WhisperKit results while you speak.
After you stop, WhisperKit makes one final pass over the complete recording and
adds the more accurate result to the draft. The composer also shows whether it
is preparing the model, listening, or finalizing the on-device transcription.

The first use downloads roughly 626 MB and prepares the model for the device.
Later launches reuse the downloaded device cache, although the app still needs
to load and prepare the model in memory once after launch. It remains loaded
for subsequent dictation during that app session.
