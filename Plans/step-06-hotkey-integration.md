# Step 6: Global Hotkey Integration (Full End-to-End)

## Goal
Wire everything into `main.py` using `pynput` global hotkeys. This is the complete product — press ⌘⇧R to start a meeting recording, press it again to stop, and a markdown note appears in your vault.

## Prerequisite
Steps 1–5 complete. All `--*-test` flags work correctly.

## What Is Usable After This Step
The full workflow. Every meeting from this point can be recorded, transcribed, cleaned, and saved with just two keypresses and a title.

---

## Key Implementation Details

### pynput + Accessibility Permission (Silent Failure Risk)

`pynput.keyboard.GlobalHotKeys` will start without any error even if Accessibility permission is not granted. The hotkey simply never fires. You have no programmatic way to detect this.

**Mitigation:** Print a clear instruction at startup:
```
If ⌘⇧R doesn't respond: System Settings → Privacy & Security → Accessibility → enable Terminal
```

Grant the permission, then restart the script.

### Threading Model

`GlobalHotKeys` runs its callback on a **background listener thread**. The entire post-stop pipeline (transcribe → Claude → `input()` → save) runs on that same thread. This is fine for a CLI tool because:
- `input()` works from non-main threads in macOS terminals
- We don't want to accept another hotkey press while a pipeline is running anyway

**Important:** While the pipeline runs (which can take 1-3 minutes for transcription + Claude), the hotkey listener is blocked. That's correct behavior.

### Ctrl+C During Recording (Graceful Shutdown)

If the user hits Ctrl+C while recording is active, the SIGINT handler must:
1. Stop the recorder (flush the partial WAV chunk)
2. Ask if they want to save the raw transcript
3. Exit cleanly

### pynput Hotkey String for macOS

The correct `GlobalHotKeys` key string for ⌘⇧R on macOS:
```python
{"<cmd>+<shift>+r": toggle_recording}
```

If this doesn't fire, try `"<ctrl>+<shift>+r"` — some versions of pynput alias Cmd to Ctrl on macOS. Test interactively.

---

## Final `main.py` (complete replacement)

```python
from __future__ import annotations

import signal
import sys
import threading
import time
from datetime import datetime

from pynput import keyboard

from config import load_config, Config
from recorder import Recorder
from transcriber import transcribe_chunks
from llm import process_transcript
from output import save_output

# ── State ────────────────────────────────────────────────────────────────────

_config: Config | None = None
_recorder: Recorder | None = None
_recording = False
_started_at: datetime | None = None
_lock = threading.Lock()  # protects _recording state


# ── Hotkey callback ───────────────────────────────────────────────────────────

def toggle_recording() -> None:
    global _recording, _recorder, _started_at

    with _lock:
        if _recording:
            # Stop recording and run the full pipeline
            _recording = False
            _run_pipeline()
        else:
            # Start recording
            _recording = True
            _started_at = datetime.now()
            _recorder = Recorder(_config.audio_device_name, _config.chunk_duration_seconds)
            _recorder.start()
            print(f"\n● Recording started [{_started_at.strftime('%H:%M:%S')}]", flush=True)
            print("Press ⌘⇧R again to stop.", flush=True)


def _run_pipeline() -> None:
    """Run after recording stops: transcribe → clean → save. Called from hotkey thread."""
    global _recorder

    print("\n■ Recording stopped. Transcribing...", flush=True)
    chunks = _recorder.stop()

    if not chunks:
        print("No audio recorded.", flush=True)
        _print_listening()
        return

    # Transcribe
    raw_transcript = transcribe_chunks(chunks, _config.whisper_model)

    if not raw_transcript.strip():
        print("No speech detected in recording.", flush=True)
        _cleanup_chunks(chunks)
        _print_listening()
        return

    # LLM cleanup
    print("Transcription complete. Cleaning up with Claude...", flush=True)
    llm_result = None
    try:
        llm_result = process_transcript(raw_transcript, _config.anthropic_api_key)
    except Exception as e:
        print(f"\nClaude API error: {e}", flush=True)
        answer = _prompt("Save raw transcript only? [y/N]: ").strip().lower()
        if answer == "y":
            from llm import LLMResult
            llm_result = LLMResult(
                cleaned_transcript=raw_transcript,
                summary="*(Summary unavailable — Claude API error)*",
            )
        else:
            _cleanup_chunks(chunks)
            _print_listening()
            return

    # Prompt for title
    title = _prompt("Meeting title: ").strip()
    if not title:
        title = "Untitled Meeting"

    # Calculate duration
    duration_minutes = max(1, int((datetime.now() - _started_at).total_seconds() / 60))

    # Save to vault
    path = save_output(
        title=title,
        started_at=_started_at,
        duration_minutes=duration_minutes,
        result=llm_result,
        vault_path=_config.vault_path,
    )

    _cleanup_chunks(chunks)
    print(f"\n✓ Saved to {path}", flush=True)
    _print_listening()


def _prompt(message: str) -> str:
    """Print a prompt and read a line of input. Works from non-main threads on macOS."""
    print(message, end="", flush=True)
    return sys.stdin.readline().rstrip("\n")


def _cleanup_chunks(chunks) -> None:
    for path in chunks:
        path.unlink(missing_ok=True)


def _print_listening() -> None:
    print("\nListening... Press ⌘⇧R to start recording.", flush=True)


# ── SIGINT handler ────────────────────────────────────────────────────────────

def _sigint_handler(signum, frame) -> None:
    global _recording, _recorder

    if _recording and _recorder:
        print("\n\nCtrl+C detected while recording. Stopping...", flush=True)
        _recording = False
        chunks = _recorder.stop()
        if chunks:
            answer = _prompt("Save raw transcript without cleanup? [y/N]: ").strip().lower()
            if answer == "y":
                from llm import LLMResult
                result = LLMResult(
                    cleaned_transcript=transcribe_chunks(chunks, _config.whisper_model),
                    summary="*(Recording interrupted — no summary generated)*",
                )
                title = _prompt("Meeting title: ").strip() or "Interrupted Meeting"
                duration_minutes = max(1, int((datetime.now() - _started_at).total_seconds() / 60))
                path = save_output(title, _started_at, duration_minutes, result, _config.vault_path)
                print(f"✓ Saved to {path}", flush=True)
            _cleanup_chunks(chunks)
    else:
        print("\nExiting.", flush=True)

    sys.exit(0)


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    global _config

    _config = load_config()

    # Register SIGINT handler before starting listener
    signal.signal(signal.SIGINT, _sigint_handler)

    # Verify audio device exists upfront
    from recorder import find_device_index
    try:
        find_device_index(_config.audio_device_name)
    except RuntimeError:
        sys.exit(1)

    print("macOS Meeting Transcriber")
    print(f"  Vault:  {_config.vault_path}")
    print(f"  Model:  {_config.whisper_model}")
    print()
    _print_listening()
    print("If ⌘⇧R doesn't respond: System Settings → Privacy & Security → Accessibility → enable Terminal")
    print()

    # Start global hotkey listener
    with keyboard.GlobalHotKeys({"<cmd>+<shift>+r": toggle_recording}) as listener:
        listener.join()


if __name__ == "__main__":
    main()
```

---

## Test

### Basic end-to-end test

```bash
python main.py
```

Expected startup output:
```
macOS Meeting Transcriber
  Vault:  /Users/yourname/Documents/Meetings
  Model:  mlx-community/whisper-small-mlx

Listening... Press ⌘⇧R to start recording.
If ⌘⇧R doesn't respond: System Settings → Privacy & Security → Accessibility → enable Terminal
```

Then:
1. Press ⌘⇧R → `● Recording started [14:30:05]`
2. Speak for 20-30 seconds
3. Press ⌘⇧R again → transcription starts
4. Type a meeting title when prompted
5. `✓ Saved to /Users/yourname/Documents/Meetings/2026-03-17 14-30 My test.md`
6. Script returns to listening state — press ⌘⇧R again to record another

### Verify the output file

```bash
cat ~/Documents/Meetings/2026-03-17*.md
```

Should show correct frontmatter, summary sections, and cleaned transcript.

### Test Ctrl+C during recording

```bash
python main.py
# Press ⌘⇧R to start
# Wait 5 seconds
# Press Ctrl+C
# Expected: "Ctrl+C detected while recording. Stopping..."
# Prompts to save raw transcript
```

### Test hotkey not working (Accessibility not granted)

If ⌘⇧R does nothing:
1. System Settings → Privacy & Security → Accessibility
2. Find Terminal (or iTerm2), toggle it on
3. Restart `python main.py`

---

## Done When
- [ ] `python main.py` starts and prints the listening message
- [ ] ⌘⇧R starts recording (prints timestamp)
- [ ] ⌘⇧R again stops, transcribes, calls Claude, prompts for title
- [ ] Markdown file appears in vault with correct content
- [ ] Script returns to listening state without restarting
- [ ] Ctrl+C during recording offers to save raw transcript
- [ ] A second meeting can be recorded in the same session

---

## The Complete Working Tool

At this point, the full V0 is done. Workflow for every meeting going forward:

1. `python main.py` (once per session, keep terminal open)
2. Join your meeting
3. ⌘⇧R → recording starts
4. ⌘⇧R → recording stops → type a title
5. Open your vault in Obsidian → note is there

---
**V0 complete!** See `Spec/macos-meeting-transcriber/spec.md` for future enhancement ideas.
