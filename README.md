# Minutes

Menu bar app that records meetings and turns them into markdown notes.
Everything runs locally except the summary: audio never leaves the machine,
transcription is whisper.cpp on-device, and only the finished *text* transcript
goes through `claude -p` for the summary.

## How it works

Two tracks, recorded simultaneously:

| track | source | captures |
|---|---|---|
| `mic.wav` | AVAudioEngine input tap | you |
| `system.wav` | ScreenCaptureKit system audio | everyone else |

System audio is tapped inside the OS, before output routing — earphones,
AirPods or speakers make no difference. The two-track split also gives
**Me/Them** speaker attribution for free, no diarization model needed.

On stop: whisper.cpp transcribes each track (16 kHz mono WAV, written in that
format live so there is no conversion step), the segments interleave by
timestamp into a single transcript, `claude -p` writes the summary, and one
markdown file lands in `~/Documents/MeetingNotes/`.

## Setup

```
./setup.sh            # installs whisper-cpp (brew) + downloads ggml-large-v3-turbo
./build_and_run.sh    # builds, bundles, signs, launches
```

The app picks the best model present:
large-v3-turbo > large-v3 > medium > small > base > tiny.
Default is large-v3-turbo (~1.6 GB): near large-v3 accuracy at medium-class
speed. `./setup.sh small` fetches the lighter one if disk or battery matter more.

First recording prompts for **Microphone** and **Screen Recording** permissions
(system audio rides on the screen-recording permission — that's a macOS
constraint, not a choice). Grant both, then start the recording again.

## Use

Menu bar waveform icon → **Start Recording**. Icon turns into a record dot.
**Stop & Make Notes** → gear icon while it transcribes and summarizes → macOS
notification when the note is ready. `Open Last Note` / `Open Notes Folder`
from the same menu.

## Behaviour worth knowing

- **Audio files are deleted after a successful note** (they're big — ~115 MB/hr).
  Toggle *Keep Audio Files* in the menu to retain them under
  `~/Library/Application Support/Minutes/recordings/`. On any pipeline failure
  the audio is always kept, so a failed transcription never loses the meeting.
- **If claude CLI is missing or fails**, the note still ships with the full
  transcript and a line saying the summary was skipped.
- **Mid-meeting device switches** (AirPods dying, headset connecting) are
  handled — the mic tap rebuilds against the new device. There is a sub-second
  gap in your track at the switch.
- **No earphones?** Your mic will also hear the others through the speakers, so
  their words can appear in your "Me" track. Cosmetic — the system track still
  has them cleanly.
- Transcription language is pinned to English (`-l en` in Pipeline.swift).
- Recording is announced to no one. Check company policy before recording
  calls, and prefer telling participants.

## Layout

```
Minutes/MinutesApp.swift   menu bar UI + state machine
Minutes/Recorder.swift     dual-track capture → 16 kHz mono WAVs
Minutes/Pipeline.swift     whisper → merge → claude → markdown
setup.sh                   whisper-cpp + model download
build_and_run.sh           SPM build → .app bundle → ad-hoc sign
```
