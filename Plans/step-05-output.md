# Step 5: Output File Assembly

## Goal
Add `output.py` so a `LLMResult` and session metadata are assembled into a properly formatted markdown file and written to the vault.

## Prerequisite
Step 4 complete. `python main.py --llm-test` returns a cleaned transcript and summary.

## What Is Usable After This Step
Run `python main.py --output-test` to generate a real markdown note in your vault using mock data. You can open it in Obsidian right away.

---

## Files to Create/Modify

### `output.py` (new file)

```python
from __future__ import annotations

import re
from datetime import datetime
from pathlib import Path

from llm import LLMResult

TEMPLATE = """\
---
date: {date}
time: {time}
duration: ~{duration} minutes
---

# {title}

## Summary

{summary}

---

## Cleaned Transcript

{cleaned_transcript}
"""


def _sanitize_filename(title: str) -> str:
    """Remove characters that are unsafe in macOS/Windows filenames."""
    title = title.strip()
    # Replace filesystem-unsafe characters
    title = re.sub(r'[/\\:*?"<>|]', "-", title)
    # Collapse multiple spaces/hyphens
    title = re.sub(r"\s+", " ", title)
    title = re.sub(r"-{2,}", "-", title)
    return title.strip(" -")


def save_output(
    title: str,
    started_at: datetime,
    duration_minutes: int,
    result: LLMResult,
    vault_path: Path,
) -> Path:
    """
    Assemble markdown content and write to vault_path.
    Returns the full path of the saved file.
    """
    safe_title = _sanitize_filename(title) or "Untitled Meeting"

    date_str = started_at.strftime("%Y-%m-%d")
    time_str = started_at.strftime("%H-%M")
    filename = f"{date_str} {time_str} {safe_title}.md"

    content = TEMPLATE.format(
        date=date_str,
        time=started_at.strftime("%H:%M"),
        duration=duration_minutes,
        title=safe_title,
        summary=result.summary,
        cleaned_transcript=result.cleaned_transcript,
    )

    output_path = vault_path / filename
    output_path.write_text(content, encoding="utf-8")
    return output_path
```

### `main.py` (updated — add `--output-test` flag)

```python
from __future__ import annotations

import signal
import sys
import time
from datetime import datetime

from config import load_config
from recorder import Recorder
from transcriber import transcribe_chunks
from llm import process_transcript, LLMResult
from output import save_output

MOCK_TRANSCRIPT = """
uh so yeah I think the main thing we need to talk about today is um the Q2 roadmap
like we've been going back and forth on this and I think we need to just make a decision
so Alice said that uh she thinks we should prioritize onboarding and Bob was like yeah
but we also need to think about the API work right so um the decision we made was
we're gonna ship onboarding v2 before end of March and the API stuff will be behind a feature flag
and then Alice is gonna share wireframes by Friday and Bob needs to estimate the API effort by end of day
"""

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


def output_test(config) -> None:
    print("Saving mock meeting note to vault...")
    started_at = datetime.now()
    path = save_output(
        title="Output Test: Q2 Roadmap Planning",
        started_at=started_at,
        duration_minutes=23,
        result=MOCK_LLM_RESULT,
        vault_path=config.vault_path,
    )
    print(f"\n✓ Saved to: {path}")
    print("\nFile contents:")
    print("-" * 40)
    print(path.read_text())


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

    if "--output-test" in sys.argv:
        output_test(config)
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
python main.py --output-test
```

Expected output:
```
Saving mock meeting note to vault...

✓ Saved to: /Users/yourname/Documents/Meetings/2026-03-17 14-30 Output Test- Q2 Roadmap Planning.md

File contents:
----------------------------------------
---
date: 2026-03-17
time: 14:30
duration: ~23 minutes
---

# Output Test- Q2 Roadmap Planning

## Summary

## Topics Discussed
- Q2 roadmap priorities
...
```

**Open in Obsidian** — navigate to your vault folder, the file should appear immediately.

**Test filename sanitization:**
```bash
# Edit output_test() temporarily to use a title with special chars:
# title="Meeting: Q2/Planning — What's Next?"
# Should produce: "2026-03-17 14-30 Meeting- Q2-Planning — What's Next-.md"
```

## Done When
- [ ] `python main.py --output-test` creates a real file in the vault
- [ ] File has correct YAML frontmatter, title, summary, and transcript sections
- [ ] File is immediately visible in Obsidian
- [ ] Titles with `/ : * ?` characters are sanitized in the filename

---
**Next:** `Plans/step-06-hotkey-integration.md`
