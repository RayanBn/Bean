# Followup

Bean hears a call so it can handle what follows. When another app starts using the microphone, Bean asks in the notch whether to take notes and reminds the user to tell the others. Only after "Take notes" does it capture the user's side (microphone) and the others' side (system audio), and transcribe both on the Mac (Apple speech, or Meta Muse Voice when chosen in settings). When the call ends, Bean hands the transcript, one line per sentence tagged `me` or `them`, to its brain. No audio is kept.

## Sub-features

- `followup-detect`: a call starts when another process holds the microphone for 3 s (`BEAN_CALL_START_SECONDS`) and ends 8 s (`BEAN_CALL_END_SECONDS`) after it lets go.
- `followup-consent`: the notch asks "Take notes…? Tell the others first." with "Not this call" and "Take notes". No answer in 30 s means no notes.
- `followup-capture`: two tracks, `me` from the microphone and `them` from a system audio tap that leaves out Bean's own sound. The tap is rebuilt when the output device changes or when no audio arrives for 5 s.
- `followup-transcribe`: Apple `SpeechTranscriber` in the user's language by default, `metaVoice` (Muse Voice, cloud, speaker labels) from settings.
- `followup-heard`: at the end of the call, a `transcribed` record with the transcript, the audio frame counts per track, and the hand-off to the brain.

## How to get to it (user POV)

- Join a call in any app (Zoom, Meet in a browser, FaceTime, Teams). The consent card appears within a few seconds.
- "Take notes in calls" and "Transcription" in the menu bar popover change the behavior (Ask each call / Never, On this Mac / Meta Muse Voice).

## Driving it with bean

Preconditions:

- `bean build` succeeded. Bean has the System Audio Recording permission (Privacy & Security > Screen & System Audio Recording). Without it, the tap delivers silence and `them` stays empty.
- A fake call script: one line per sentence, `me|<voice>|<text>` or `them|<voice>|<text>` (voices from `say -v '?'`).

- **Prepare.** `bean call-prepare <script>` writes `me.caf` and `them.caf` to the run directory: each side's lines at their times, silence elsewhere.
- **Launch.** `BEAN_MIC_FILE=$RUN/me.caf BEAN_CALL_END_SECONDS=4 BEAN_CALL_LOCALE=en_US bean launch`. The mic file stands in for the user's voice; the system audio path is real.
- **Call starts.** `bean call-start` holds the real microphone, like a meeting app. Within ~20 s `bean hearing` shows `callStarted`, and `bean shot consent` shows the card.
- **Consent.** `bean press "Take notes"`, then right away `bean call-play` plays `them.caf` through the speakers. `bean hearing` shows `consented`, then `recording` with the transcriber and locale.
- **Call ends.** `bean call-end` releases the mic. About 4 s later `bean hearing` shows `callEnded`, then `transcribed` with both sides in order and `audio` frame counts for `me` and `them`, where the second number (loud frames) is above zero.
- **Decline.** Same start, `bean press "Not this call"`: `declined`, and no `recording`.
- **Focus.** `bean frontmost` is unchanged after each press.

## Gotchas

- `call-start` compiles the mic holder once into `~/Library/Caches`; Bean sees the call about 3 s after it starts. Wait for `callStarted` before pressing.
- Press "Take notes" and play `them.caf` in the same command, or the `them` lines are offset by the delay.
- Pick clear `say` voices: Samantha and Daniel (English) and Thomas (French) transcribe well; Flo, Eddy and Amélie come out garbled even outside Bean.
- Any app holding the mic starts a call for Bean, dictation tools and another run's probes included.
- Speakers make the microphone hear the others. Real calls need headphones; the mic file avoids this in runs.
- Another verify run may hold the notch lock for minutes; `bean launch` waits.
