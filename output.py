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
    title = re.sub(r'[/\\:*?"<>|]', "-", title)
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
    """Assemble markdown content and write to vault_path. Returns the saved file path."""
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
