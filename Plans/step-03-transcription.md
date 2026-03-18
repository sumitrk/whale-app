# Step 3: Local Transcription with mlx-whisper

## Goal
Add `transcriber.py` so a list of WAV chunk paths is transcribed to text locally on Apple Silicon. Usable standalone — pass any WAV file, get a transcript.

## Prerequisite
Step 2 complete. `python main.py --record-test` produces a valid WAV file.

## What Is Usable After This Step
Run `python main.py --transcribe-test` to record 15 seconds, then immediately transcribe it to text using Whisper. The full audio-to-text pipeline works offline, no API needed.

---

## Important: First-Run Model Download

On the very first call to `mlx_whisper.transcribe`, the model is downloaded from HuggingFace:
- `whisper-large-v3-mlx` → **~3 GB**, can take 5-10 minutes
- `whisper-small-mlx` → **~150 MB**, downloads in ~30 seconds

**Recommendation during development:** Set `WHISPER_MODEL=mlx-community/whisper-small-mlx` in `.env` while building. Switch to `large-v3` when you want production quality.

The model is cached at `~/.cache/huggingface/hub/` and only downloaded once.

---

## Files to Create/Modify

### `transcriber.py` (new file)

```python
from __future__ import annotations

import sys
from pathlib import Path

import mlx_whisper

# Cache path for the model (used to detect first-run)
_HF_CACHE = Path.home() / ".cache" / "huggingface" / "hub"


def _model_is_cached(model_repo: str) -> bool:
    """Check if the HuggingFace model is already downloaded locally."""
    # HF cache dir name: models--<org>--<model> with / replaced by --
    cache_name = "models--" + model_repo.replace("/", "--")
    return (_HF_CACHE / cache_name).exists()


def transcribe_chunks(chunk_paths: list[Path], model: str) -> str:
    """
    Transcribe a list of WAV chunk files in order.
    Returns the concatenated raw transcript string.
    """
    if not chunk_paths:
        return ""

    if not _model_is_cached(model):
        print(f"First run: downloading Whisper model '{model}'...")
        print("This may take several minutes (~3 GB for large-v3, ~150 MB for small).")
        print("Tip: set WHISPER_MODEL=mlx-community/whisper-small-mlx in .env for faster downloads.\n")

    total = len(chunk_paths)
    texts: list[str] = []

    for i, path in enumerate(chunk_paths, start=1):
        print(f"Transcribing chunk {i}/{total}: {path.name}...", flush=True)
        result = mlx_whisper.transcribe(
            str(path),
            path_or_hf_repo=model,
            verbose=False,
        )
        text = result.get("text", "").strip()
        texts.append(text)

    return "\n".join(texts)
```

### `main.py` (updated — add `--transcribe-test` flag)

```python
from __future__ import annotations

import signal
import sys
import time

from config import load_config
from recorder import Recorder
from transcriber import transcribe_chunks


def record_test(config) -> None:
    print("Recording 10 seconds... (speak something or play audio)")
    recorder = Recorder(config.audio_device_name, chunk_duration_seconds=30)
    recorder.start(session_id="test")
    try:
        time.sleep(10)
    except KeyboardInterrupt:
        pass
    chunks = recorder.stop()
    print(f"\nRecording complete. {len(chunks)} chunk(s) saved:")
    for path in chunks:
        print(f"  {path}")
    print("\nPlay back with:")
    for path in chunks:
        print(f"  afplay {path}")


def transcribe_test(config) -> None:
    print("Recording 15 seconds... speak clearly into your mic.")
    recorder = Recorder(config.audio_device_name, chunk_duration_seconds=30)
    recorder.start(session_id="transcribe-test")

    try:
        time.sleep(15)
    except KeyboardInterrupt:
        pass

    chunks = recorder.stop()
    print(f"\n■ Recording stopped. {len(chunks)} chunk(s).")
    print("\nTranscribing...")

    raw = transcribe_chunks(chunks, config.whisper_model)

    print("\n--- Raw Transcript ---")
    print(raw if raw.strip() else "(no speech detected)")
    print("----------------------")

    # Clean up temp files
    for path in chunks:
        path.unlink(missing_ok=True)


def main() -> None:
    config = load_config()

    if "--record-test" in sys.argv:
        record_test(config)
        return

    if "--transcribe-test" in sys.argv:
        transcribe_test(config)
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

## Test

```bash
# Recommended: use the small model for first test (fast download)
# Edit .env: WHISPER_MODEL=mlx-community/whisper-small-mlx

python main.py --transcribe-test
```

Expected output:
```
Audio device: MeetingAggregate (index 4)
Recording 15 seconds... speak clearly into your mic.
  Saved chunk 1: chunk_001.wav (461 KB)

■ Recording stopped. 1 chunk(s).

Transcribing...
First run: downloading Whisper model 'mlx-community/whisper-small-mlx'...
This may take several minutes (~3 GB for large-v3, ~150 MB for small).
Tip: set WHISPER_MODEL=mlx-community/whisper-small-mlx in .env for faster downloads.

Transcribing chunk 1/1: chunk_001.wav...

--- Raw Transcript ---
 Hello, this is a test recording. I'm speaking to check that the transcription is working correctly.
----------------------
```

**Also test with an existing WAV file** (e.g. from step 2):
```bash
# You can test transcriber.py directly:
python3 -c "
from pathlib import Path
from transcriber import transcribe_chunks
import os; os.environ.setdefault('WHISPER_MODEL', 'mlx-community/whisper-small-mlx')
chunks = [Path('/tmp/transcribe-meetings/test/chunk_001.wav')]
print(transcribe_chunks(chunks, 'mlx-community/whisper-small-mlx'))
"
```

## Done When
- [ ] `python main.py --transcribe-test` records audio and prints a transcript
- [ ] Spoken words appear correctly (not perfectly — small model is good enough for testing)
- [ ] First run downloads the model automatically with a clear progress message
- [ ] Temp files are cleaned up after the test

---
**Next:** `Plans/step-04-llm-cleanup.md`
