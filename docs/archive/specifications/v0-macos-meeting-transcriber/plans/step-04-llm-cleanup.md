# Step 4: LLM Cleanup + Summary via Claude

## Goal
Add `llm.py` so a raw transcript string is sent to Claude and returned as a structured result with a cleaned transcript and meeting summary.

## Prerequisite
Step 3 complete. `python main.py --transcribe-test` produces a transcript.

## What Is Usable After This Step
Run `python main.py --llm-test` to clean a hardcoded mock transcript and get a formatted summary. The Claude integration is verified end-to-end.

---

## Files to Create/Modify

### `llm.py` (new file)

```python
from __future__ import annotations

import json
import re
from dataclasses import dataclass

import anthropic

SYSTEM_PROMPT = """You are a meeting transcription assistant. You will receive a raw speech-to-text transcript of a meeting and must return a JSON object with two fields:
- "cleaned_transcript": The transcript with filler words removed (uh, um, like, you know), run-on sentences broken up, and punctuation corrected. Preserve the speaker's meaning exactly.
- "summary": A structured markdown summary with exactly these sections:
  ## Topics Discussed
  ## Decisions Made
  ## Open Questions / Next Steps

Return only valid JSON. No commentary, no code fences, no extra text."""

MODEL = "claude-sonnet-4-6"


@dataclass
class LLMResult:
    cleaned_transcript: str
    summary: str


def _strip_code_fences(text: str) -> str:
    """Remove markdown code fences if Claude wraps the JSON in them."""
    text = text.strip()
    # Match ```json ... ``` or ``` ... ```
    match = re.match(r"^```(?:json)?\s*\n?(.*?)\n?```$", text, re.DOTALL)
    if match:
        return match.group(1).strip()
    return text


def process_transcript(raw_transcript: str, api_key: str) -> LLMResult:
    """
    Send raw transcript to Claude for cleanup and summarization.
    Returns LLMResult with cleaned_transcript and summary.
    Raises on API error or JSON parse failure.
    """
    client = anthropic.Anthropic(api_key=api_key)

    response = client.messages.create(
        model=MODEL,
        max_tokens=8096,
        system=SYSTEM_PROMPT,
        messages=[
            {
                "role": "user",
                "content": f"<raw_transcript>\n{raw_transcript}\n</raw_transcript>",
            }
        ],
    )

    raw_response = response.content[0].text
    cleaned = _strip_code_fences(raw_response)

    try:
        data = json.loads(cleaned)
    except json.JSONDecodeError as e:
        print(f"\nERROR: Claude returned invalid JSON.")
        print(f"Parse error: {e}")
        print(f"Raw response:\n{raw_response[:500]}")
        raise

    return LLMResult(
        cleaned_transcript=data.get("cleaned_transcript", "").strip(),
        summary=data.get("summary", "").strip(),
    )
```

### `main.py` (updated — add `--llm-test` flag)

```python
from __future__ import annotations

import signal
import sys
import time

from config import load_config
from recorder import Recorder
from transcriber import transcribe_chunks
from llm import process_transcript

# Mock transcript for --llm-test
MOCK_TRANSCRIPT = """
uh so yeah I think the main thing we need to talk about today is um the Q2 roadmap
like we've been going back and forth on this and I think we need to just make a decision
so Alice said that uh she thinks we should prioritize onboarding and Bob was like yeah
but we also need to think about the API work right so um the decision we made was
we're gonna ship onboarding v2 before end of March and the API stuff will be behind a feature flag
and then Alice is gonna share wireframes by Friday and Bob needs to estimate the API effort by end of day
"""


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
    for path in chunks:
        path.unlink(missing_ok=True)


def llm_test(config) -> None:
    print("Sending mock transcript to Claude...")
    print(f"Model: claude-sonnet-4-6\n")

    try:
        result = process_transcript(MOCK_TRANSCRIPT.strip(), config.anthropic_api_key)
    except Exception as e:
        print(f"\nFailed: {e}")
        sys.exit(1)

    print("--- Cleaned Transcript ---")
    print(result.cleaned_transcript)
    print()
    print("--- Summary ---")
    print(result.summary)
    print("---------------")


def main() -> None:
    config = load_config()

    if "--record-test" in sys.argv:
        record_test(config)
        return

    if "--transcribe-test" in sys.argv:
        transcribe_test(config)
        return

    if "--llm-test" in sys.argv:
        llm_test(config)
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
python main.py --llm-test
```

Expected output:
```
Sending mock transcript to Claude...
Model: claude-sonnet-4-6

--- Cleaned Transcript ---
The main topic for today is the Q2 roadmap. After back-and-forth discussion, Alice suggested
prioritizing onboarding while Bob raised the importance of the API work. We reached a decision:
ship onboarding v2 before end of March, with API work behind a feature flag initially.

--- Summary ---
## Topics Discussed
- Q2 roadmap priorities
- Onboarding v2 timeline
- API work scope and rollout approach

## Decisions Made
- Ship onboarding v2 before end of March
- API v2 will be behind a feature flag initially

## Open Questions / Next Steps
- [ ] Alice to share wireframes by Friday
- [ ] Bob to estimate API v2 effort by end of day
---------------
```

**If Claude API key is invalid:**
```
anthropic.AuthenticationError: ...
```
Check `ANTHROPIC_API_KEY` in `.env`.

## Done When
- [ ] `python main.py --llm-test` returns a cleaned transcript and structured summary
- [ ] JSON is parsed correctly (no errors about code fences or format)
- [ ] Invalid API key produces a readable error (not a Python traceback)

---
**Next:** `Plans/step-05-output.md`
