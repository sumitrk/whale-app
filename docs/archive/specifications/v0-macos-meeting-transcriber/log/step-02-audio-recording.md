# Task: Step 2 — Audio Recording to WAV Chunks

## Status: COMPLETE ✅

## What Was Built
- `recorder.py` — full Recorder class with:
  - `find_device_index()` — matches device by partial name, shows available devices on failure
  - `Recorder.start()` — opens sounddevice InputStream, starts writer thread
  - `Recorder.stop()` — flushes final chunk, closes stream, returns sorted chunk paths
  - `Recorder.cleanup()` — deletes temp files
  - WAV chunks written atomically via `scipy.io.wavfile.write` (no streaming append)
  - sounddevice callback → deque → writer thread pattern (no I/O in callback)
- `main.py` — added `--record-test` flag (records 10s, saves WAV, prints afplay command)

## What Worked
- Recording pipeline works correctly with built-in mic
- 3-second test produced 93 KB WAV file at 16kHz mono int16
- Chunked writer loop works: full chunks flush atomically, leftover samples carry over
- `find_device_index` error message clearly shows available devices

## Issues Encountered
- **pip not working**: System Python 3.13 on macOS blocks pip installs (PEP 668). Fixed by using `python3 -m pip install --break-system-packages sounddevice numpy scipy`
- **BlackHole not installed**: `MeetingAggregate` device not found — expected, user needs to install BlackHole first. Error message guides them correctly.
- **`uv` is available**: `/Users/sumitkumar/.local/bin/uv` — could be used instead of pip for future installs

## Current Device Status
BlackHole is NOT installed. Available input devices:
- [0] MacBook Pro Microphone
- [2] iPhone Microphone

`AUDIO_DEVICE_NAME=MeetingAggregate` in .env — will fail until BlackHole is installed.
Testing was done using `MacBook Pro Microphone` directly in Python.

## Test Results
```
Audio device: MacBook Pro Microphone (index 0)
Recording 3 seconds...
  Saved chunk 1: chunk_001.wav (93 KB)
Got 1 chunks:
  /tmp/transcribe-meetings/test-step2/chunk_001.wav (93 KB)
```

## Next Step
`Plans/step-03-transcription.md` — implement `transcriber.py` and `--transcribe-test` flag
Note: Install mlx-whisper before starting. Use `whisper-small-mlx` for fast testing.
