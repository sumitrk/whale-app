from __future__ import annotations

import signal
import sys
import threading
import time
from datetime import datetime

from pynput import keyboard

from config import load_config, Config
from llm import LLMResult, process_transcript
from output import save_output
from recorder import Recorder, find_device_index
from transcriber import transcribe_chunks

# ── Test helpers (kept for debugging) ────────────────────────────────────────

MOCK_TRANSCRIPT = """
uh so yeah I think the main thing we need to talk about today is um the Q2 roadmap
like we've been going back and forth on this and I think we need to just make a decision
so Alice said that uh she thinks we should prioritize onboarding and Bob was like yeah
but we also need to think about the API work right so um the decision we made was
we're gonna ship onboarding v2 before end of March and the API stuff will be behind a feature flag
and then Alice is gonna share wireframes by Friday and Bob needs to estimate the API effort by end of day
""".strip()

MOCK_LLM_RESULT = LLMResult(
    cleaned_transcript=(
        "The main topic for today is the Q2 roadmap. After discussion, Alice suggested "
        "prioritizing onboarding while Bob raised the importance of API work. We decided to ship "
        "onboarding v2 before end of March, with API work behind a feature flag initially."
    ),
    summary=(
        "## Topics Discussed\n"
        "- Q2 roadmap priorities\n"
        "- Onboarding v2 timeline\n"
        "- API v2 rollout approach\n\n"
        "## Decisions Made\n"
        "- Ship onboarding v2 before end of March\n"
        "- API v2 will be behind a feature flag\n\n"
        "## Open Questions / Next Steps\n"
        "- [ ] Alice to share wireframes by Friday\n"
        "- [ ] Bob to estimate API v2 effort by EOD"
    ),
)


def record_test(config) -> None:
    print("Recording 10 seconds... (speak something or play audio)")
    recorder = Recorder(config.audio_device_name, chunk_duration_seconds=30)
    recorder.start(session_id="test")
    try:
        time.sleep(10)
    except KeyboardInterrupt:
        pass
    chunks = recorder.stop()
    print()
    if chunks:
        print(f"Recording complete. {len(chunks)} chunk(s) saved:")
        for path in chunks:
            print(f"  {path}")
        print("\nPlay back with:")
        for path in chunks:
            print(f"  afplay {path}")
    else:
        print("No audio chunks saved.")


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
    if not chunks:
        print("No audio recorded.")
        return
    print("\nTranscribing...")
    raw = transcribe_chunks(chunks, config.whisper_model)
    print("\n--- Raw Transcript ---")
    print(raw if raw.strip() else "(no speech detected)")
    print("----------------------")
    for path in chunks:
        path.unlink(missing_ok=True)


def llm_test(config) -> None:
    print("Sending mock transcript to Claude...")
    print("Model: claude-sonnet-4-6\n")
    try:
        result = process_transcript(MOCK_TRANSCRIPT, config.anthropic_api_key)
    except Exception as e:
        print(f"\nFailed: {e}")
        sys.exit(1)
    print("--- Cleaned Transcript ---")
    print(result.cleaned_transcript)
    print()
    print("--- Summary ---")
    print(result.summary)
    print("---------------")


def output_test(config) -> None:
    print("Saving mock meeting note to vault...")
    path = save_output(
        title="Output Test: Q2 Roadmap Planning",
        started_at=datetime.now(),
        duration_minutes=23,
        result=MOCK_LLM_RESULT,
        vault_path=config.vault_path,
    )
    print(f"\n✓ Saved to: {path}")
    print("\nFile contents:")
    print("-" * 40)
    print(path.read_text())


# ── Production state ──────────────────────────────────────────────────────────

_config: Config | None = None
_recorder: Recorder | None = None
_recording = False
_started_at: datetime | None = None
_lock = threading.Lock()


# ── Hotkey callback ───────────────────────────────────────────────────────────

def toggle_recording() -> None:
    global _recording, _recorder, _started_at

    with _lock:
        if _recording:
            _recording = False
            _run_pipeline()
        else:
            _recording = True
            _started_at = datetime.now()
            _recorder = Recorder(_config.audio_device_name, _config.chunk_duration_seconds)
            _recorder.start()
            print(f"\n● Recording started [{_started_at.strftime('%H:%M:%S')}]", flush=True)
            print("Press ⌘⇧R again to stop.", flush=True)


def _run_pipeline() -> None:
    global _recorder

    print("\n■ Recording stopped. Transcribing...", flush=True)
    chunks = _recorder.stop()

    if not chunks:
        print("No audio recorded.", flush=True)
        _print_listening()
        return

    raw_transcript = transcribe_chunks(chunks, _config.whisper_model)

    if not raw_transcript.strip():
        print("No speech detected in recording.", flush=True)
        _cleanup_chunks(chunks)
        _print_listening()
        return

    print("Transcription complete. Cleaning up with Claude...", flush=True)
    llm_result = None
    try:
        llm_result = process_transcript(raw_transcript, _config.anthropic_api_key)
    except Exception as e:
        print(f"\nClaude API error: {e}", flush=True)
        answer = _prompt("Save raw transcript only? [y/N]: ").strip().lower()
        if answer == "y":
            llm_result = LLMResult(
                cleaned_transcript=raw_transcript,
                summary="*(Summary unavailable — Claude API error)*",
            )
        else:
            _cleanup_chunks(chunks)
            _print_listening()
            return

    title = _prompt("Meeting title: ").strip()
    if not title:
        title = "Untitled Meeting"

    duration_minutes = max(1, int((datetime.now() - _started_at).total_seconds() / 60))

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
                raw = transcribe_chunks(chunks, _config.whisper_model)
                result = LLMResult(
                    cleaned_transcript=raw,
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

    # Route to test commands
    if "--record-test" in sys.argv:
        record_test(_config)
        return
    if "--transcribe-test" in sys.argv:
        transcribe_test(_config)
        return
    if "--llm-test" in sys.argv:
        llm_test(_config)
        return
    if "--output-test" in sys.argv:
        output_test(_config)
        return

    # Verify audio device exists upfront (fail fast)
    try:
        find_device_index(_config.audio_device_name)
    except RuntimeError:
        sys.exit(1)

    signal.signal(signal.SIGINT, _sigint_handler)

    print("macOS Meeting Transcriber")
    print(f"  Vault:  {_config.vault_path}")
    print(f"  Model:  {_config.whisper_model}")
    print()
    _print_listening()
    print("Tip: If ⌘⇧R doesn't respond → System Settings → Privacy & Security → Accessibility → enable Terminal")

    with keyboard.GlobalHotKeys({"<cmd>+<shift>+r": toggle_recording}) as listener:
        listener.join()


if __name__ == "__main__":
    main()
