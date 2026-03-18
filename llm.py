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
    match = re.match(r"^```(?:json)?\s*\n?(.*?)\n?```$", text, re.DOTALL)
    if match:
        return match.group(1).strip()
    return text


def process_transcript(raw_transcript: str, api_key: str) -> LLMResult:
    """
    Send raw transcript to Claude for cleanup and summarization.
    Returns LLMResult with cleaned_transcript and summary.
    Raises on API error or unrecoverable JSON parse failure.
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
        print(f"Raw response (first 500 chars):\n{raw_response[:500]}")
        raise

    return LLMResult(
        cleaned_transcript=data.get("cleaned_transcript", "").strip(),
        summary=data.get("summary", "").strip(),
    )
