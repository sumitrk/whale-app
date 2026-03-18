# Step 2: Audio Recording to WAV Chunks

## Goal
Add `recorder.py` so you can actually record audio from the BlackHole aggregate device, verify it captures both mic and system audio, and play it back.

## Prerequisite
Step 1 complete. `python main.py` runs without errors.

## What Is Usable After This Step
Run `python main.py --record-test` to record 10 seconds of audio and play it back. You can verify BlackHole routing is working before writing any transcription code.

---

## Background: How Chunked WAV Recording Works

**sounddevice callback threading:**
The `sd.InputStream` fires its callback on a high-priority audio thread. You must NEVER do file I/O inside the callback. The callback should only append incoming frames to a thread-safe buffer (a `collections.deque`).

A separate **writer thread** drains the deque, accumulates samples into a numpy array, and writes a WAV file when the chunk boundary is reached (or when `stop()` is called).

**Why no streaming WAV append:**
WAV headers encode the total frame count. You cannot open a file and append audio. Instead: accumulate `CHUNK_DURATION_SECONDS × 16000` samples in memory per chunk, then write atomically with `scipy.io.wavfile.write`. For 5-min chunks this is 4.8M samples ≈ 9.6 MB RAM — completely fine.

---

## Files to Create/Modify

### `recorder.py` (new file)

```python
from __future__ import annotations

import collections
import threading
import time
import uuid
from pathlib import Path

import numpy as np
import sounddevice as sd
from scipy.io import wavfile

SAMPLE_RATE = 16_000
CHANNELS = 1
DTYPE = "int16"


def find_device_index(name: str) -> int:
    """Find input device index by partial name match."""
    devices = sd.query_devices()
    for i, device in enumerate(devices):
        if name.lower() in device["name"].lower() and device["max_input_channels"] > 0:
            return i
    # Print available input devices to help the user fix the issue
    print(f"\nERROR: Audio device '{name}' not found.")
    print("Available input devices:")
    for i, device in enumerate(devices):
        if device["max_input_channels"] > 0:
            print(f"  [{i}] {device['name']}")
    print(f"\nFix: Set AUDIO_DEVICE_NAME in .env to one of the names above.")
    raise RuntimeError(f"Audio device '{name}' not found")


class Recorder:
    def __init__(self, device_name: str, chunk_duration_seconds: int):
        self._device_name = device_name
        self._chunk_duration = chunk_duration_seconds
        self._session_dir: Path | None = None
        self._stream: sd.InputStream | None = None
        self._writer_thread: threading.Thread | None = None
        self._stop_event = threading.Event()
        self._buffer: collections.deque = collections.deque()
        self._chunk_paths: list[Path] = []

    def start(self, session_id: str | None = None) -> None:
        session_id = session_id or str(uuid.uuid4())[:8]
        self._session_dir = Path(f"/tmp/transcribe-meetings/{session_id}")
        self._session_dir.mkdir(parents=True, exist_ok=True)
        self._chunk_paths = []
        self._stop_event.clear()

        device_index = find_device_index(self._device_name)
        print(f"Audio device: {sd.query_devices()[device_index]['name']} (index {device_index})")

        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype=DTYPE,
            device=device_index,
            callback=self._audio_callback,
        )

        self._writer_thread = threading.Thread(target=self._writer_loop, daemon=True)
        self._writer_thread.start()
        self._stream.start()

    def stop(self) -> list[Path]:
        """Stop recording. Returns sorted list of chunk WAV paths."""
        self._stop_event.set()
        if self._stream:
            self._stream.stop()
            self._stream.close()
            self._stream = None
        if self._writer_thread:
            self._writer_thread.join(timeout=10)
            self._writer_thread = None
        return sorted(self._chunk_paths)

    def cleanup(self) -> None:
        """Delete all temp chunk files for this session."""
        if self._session_dir and self._session_dir.exists():
            for f in self._session_dir.glob("*.wav"):
                f.unlink()
            self._session_dir.rmdir()

    # --- Internal ---

    def _audio_callback(self, indata: np.ndarray, frames: int, time_info, status) -> None:
        if status:
            print(f"[audio] {status}", flush=True)
        # Copy to avoid reuse of the buffer by sounddevice
        self._buffer.append(indata.copy())

    def _writer_loop(self) -> None:
        chunk_samples = self._chunk_duration * SAMPLE_RATE
        accumulated: list[np.ndarray] = []
        total_frames = 0
        chunk_index = 1

        while not self._stop_event.is_set() or self._buffer:
            # Drain what's available
            while self._buffer:
                frames = self._buffer.popleft()
                accumulated.append(frames)
                total_frames += len(frames)

            # Check if chunk is full
            if total_frames >= chunk_samples:
                self._flush_chunk(accumulated, chunk_samples, chunk_index)
                # Keep leftover frames for next chunk
                full_array = np.concatenate(accumulated, axis=0)
                leftover = full_array[chunk_samples:]
                accumulated = [leftover] if len(leftover) > 0 else []
                total_frames = len(leftover)
                chunk_index += 1

            time.sleep(0.01)  # 10ms poll

        # Flush final partial chunk (always, even if very short)
        if accumulated:
            self._flush_chunk(accumulated, total_frames, chunk_index)

    def _flush_chunk(
        self, accumulated: list[np.ndarray], n_frames: int, chunk_index: int
    ) -> None:
        if not accumulated:
            return
        audio = np.concatenate(accumulated, axis=0)[:n_frames]
        audio = audio.flatten()  # mono: (N, 1) → (N,)
        path = self._session_dir / f"chunk_{chunk_index:03d}.wav"
        wavfile.write(str(path), SAMPLE_RATE, audio)
        self._chunk_paths.append(path)
        size_kb = path.stat().st_size // 1024
        print(f"  Saved chunk {chunk_index}: {path.name} ({size_kb} KB)")
```

### `main.py` (updated — add `--record-test` flag)

```python
from __future__ import annotations

import signal
import sys
import time

from config import load_config
from recorder import Recorder


def record_test(config) -> None:
    """Record 10 seconds of audio and print the file paths."""
    print("Recording 10 seconds... (speak something or play audio)")
    recorder = Recorder(config.audio_device_name, chunk_duration_seconds=30)  # 30s so no mid-test chunk
    recorder.start(session_id="test")

    try:
        time.sleep(10)
    except KeyboardInterrupt:
        pass

    chunks = recorder.stop()
    print()
    print(f"Recording complete. {len(chunks)} chunk(s) saved:")
    for path in chunks:
        print(f"  {path}")
    print()
    print("Play back with:")
    for path in chunks:
        print(f"  afplay {path}")


def main() -> None:
    config = load_config()

    if "--record-test" in sys.argv:
        record_test(config)
        return

    print(f"Config loaded:")
    print(f"  Vault:        {config.vault_path}")
    print(f"  Audio device: {config.audio_device_name}")
    print(f"  Whisper model:{config.whisper_model}")
    print(f"  Chunk size:   {config.chunk_duration_seconds}s")
    print()
    print("Listening... Press ⌘⇧R to start recording.")
    print("(Hotkey not yet wired — press Ctrl+C to exit)")

    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    signal.pause()


if __name__ == "__main__":
    main()
```

---

## BlackHole Setup (One-Time)

If you haven't set up BlackHole yet:

```bash
brew install blackhole-2ch
```

Then open **Audio MIDI Setup** (search in Spotlight):

1. Click `+` at bottom-left → **Create Multi-Output Device**
   - Check: BlackHole 2ch + Built-in Output (your speakers/headphones)
   - Set this as your system output: right-click → "Use This Device For Sound Output"

2. Click `+` → **Create Aggregate Device**
   - Check: BlackHole 2ch + your microphone input (Built-in Microphone)
   - Name it exactly: `MeetingAggregate`

3. In `.env`, set: `AUDIO_DEVICE_NAME=MeetingAggregate`

**Grant microphone permission:**
Run `python main.py --record-test` — macOS will prompt for microphone access. Grant it.

---

## Test

```bash
python main.py --record-test
```

Expected output:
```
Audio device: MeetingAggregate (index 4)
Recording 10 seconds... (speak something or play audio)
  Saved chunk 1: chunk_001.wav (308 KB)

Recording complete. 1 chunk(s) saved:
  /tmp/transcribe-meetings/test/chunk_001.wav

Play back with:
  afplay /tmp/transcribe-meetings/test/chunk_001.wav
```

Then verify:
```bash
afplay /tmp/transcribe-meetings/test/chunk_001.wav
```

You should hear your voice AND any system audio (music, meeting audio) that was playing.

**If device not found:**
```
ERROR: Audio device 'MeetingAggregate' not found.
Available input devices:
  [0] Built-in Microphone
  [2] BlackHole 2ch
  ...
Fix: Set AUDIO_DEVICE_NAME in .env to one of the names above.
```

Set `AUDIO_DEVICE_NAME` to the exact name shown.

## Done When
- [ ] `python main.py --record-test` records 10 seconds without errors
- [ ] `afplay` plays back the recording with audible audio
- [ ] System audio (from Google Meet, music, etc.) is captured alongside mic

---
**Next:** `Plans/step-03-transcription.md`
