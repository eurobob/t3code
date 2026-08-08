# Dictating in T3 Vision

T3 Vision starts every dictation immediately with Apple's on-device speech
recognizer. In the background it prepares two private WhisperKit upgrades:
multilingual Base first, followed by compressed Large v3. Audio is not sent to a
T3 server or third-party transcription service. T3 supplies project and thread
vocabulary to Apple's streaming recognizer, while WhisperKit gets a smaller,
stable product vocabulary so branch names cannot be hallucinated from its
decoder prompt.

WhisperKit begins preparing when T3 Vision launches. The composer reports cache
checking, download progress, model loading, or a preparation failure, but the
record control remains available throughout.

Select the microphone in the composer once to start recording and again to
stop. The dictation panel first shows system partial results. When a WhisperKit
tier becomes ready, recording continues uninterrupted. After you stop, the best
available WhisperKit tier makes a final pass. T3 uses that result only when it
plausibly agrees with the streaming transcript; otherwise it keeps the system
result instead of replacing valid speech with a hallucination.

The first WhisperKit upgrade downloads roughly 147 MB; the later Large v3
upgrade is roughly 626 MB. Later launches reuse both device caches, although the
app still loads each model into memory after launch. Prepared models remain
loaded for subsequent dictation during that app session.
