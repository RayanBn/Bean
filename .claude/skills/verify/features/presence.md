# Presence

Bean knows when the user is in a meeting, so it can stay quiet. It reads whether the microphone or a camera is in use by any app, and whether a meeting app is in front: Zoom, Teams, FaceTime, Webex, or a browser tab on a Google Meet call, Teams or the Zoom web app. None of this asks for a permission.

## Sub-features

- `presence-mic`: `micInUse` is true while another app records audio.
- `presence-camera`: `cameraInUse` is true while any app uses a camera.
- `presence-meeting-app`: `meetingApp` names the frontmost meeting app or meeting host. The Google Meet home page does not count, only a meeting code URL.
- `presence-in-meeting`: `inMeeting` is true when any of the three is.

## How to get to it (user POV)

- Join a call, record audio, or open the camera. Bean sees it within one read.
- For a check without the notch, `bean probe-presence` prints the timing of 20 reads and the state as JSON.

## Driving it with bean

Preconditions:

- `bean build` succeeded. No call or recording is running, so `bean probe-presence` starts all false.

- **Idle.** `bean probe-presence` prints `{"cameraInUse":false,"inMeeting":false,"micInUse":false}`.
- **Mic.** Start `ffmpeg -f avfoundation -i ":0" -t 8 -y "$RUN/mic.wav" &`, wait 3 s, run `bean probe-presence`. Expect `"micInUse":true,"inMeeting":true`. After ffmpeg ends, it is false again. Delete the recording.
- **Camera.** `open -a "Photo Booth"`, wait 5 s, `bean probe-presence`. Expect `"cameraInUse":true`. Quit Photo Booth: it is false again.
- **Meet home.** Arc in front on `https://meet.google.com/home` gives no `meetingApp`.
- **Speed.** `median` and `max` stay well under 100 ms.
- **Proof.** The probe lines are appended to `artifacts/verify/$BEAN_RUN_ID/probe-presence.txt`.

## Gotchas

- ffmpeg needs a second or two to open the mic. Probe 3 s after the start.
- ffmpeg on the camera hangs without the `nv12` pixel format and without camera access for the launching app. Photo Booth needs no prompt.
- Any app that holds the mic counts, dictation tools included.
- Never screenshot while the camera is on.
