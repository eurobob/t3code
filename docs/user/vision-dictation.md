# Dictating in T3 Vision

T3 Vision transcribes dictation privately on Apple Vision Pro using WhisperKit
and a compressed Large v3 Turbo model. Audio is not sent to a T3 server or a
third-party transcription service.

Select the microphone in the composer once to start recording and again to
stop. WhisperKit transcribes the completed recording and adds the result to the
draft. The composer shows whether it is preparing the model, listening, or
transcribing on device.

The first use downloads roughly 626 MB and prepares the model for the device.
Later launches reuse the downloaded device cache, although the app still needs
to load and prepare the model in memory once after launch. It remains loaded
for subsequent dictation during that app session.
