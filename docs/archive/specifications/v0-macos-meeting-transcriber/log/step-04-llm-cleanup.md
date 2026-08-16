# Task: Step 4 — LLM Cleanup + Summary via Claude

## Status: COMPLETE ✅

## What Was Built
- `llm.py` — `process_transcript(raw_transcript, api_key) -> LLMResult`
  - Single Claude API call (`claude-sonnet-4-6`)
  - Handles markdown code fence stripping (Claude sometimes wraps JSON in ``` fences)
  - Returns `LLMResult(cleaned_transcript, summary)` dataclass
- `main.py` — added `--llm-test` flag with a hardcoded mock transcript

## What Worked
- Claude returned clean JSON on first try — no code fences needed to strip
- Filler word removal worked well: "uh", "um", "like", "you know" all stripped
- Summary structured correctly with the three required sections
- `pynput` also installed in this step (needed for step 6): `pynput==1.8.1`

## Test Results
```
--- Cleaned Transcript ---
So I think the main thing we need to talk about today is the Q2 roadmap. We've been going
back and forth on this, and I think we need to just make a decision. Alice said that she
thinks we should prioritize onboarding, and Bob said yes, but we also need to think about
the API work. The decision we made was: we're going to ship onboarding v2 before end of March,
and the API stuff will be behind a feature flag. Alice is going to share wireframes by Friday,
and Bob needs to estimate the API effort by end of day.

--- Summary ---
## Topics Discussed
- Q2 roadmap planning
- Prioritization of onboarding work (Alice's recommendation)
- API work and its timeline (raised by Bob)

## Decisions Made
- Onboarding v2 will ship before end of March
- API work will be released behind a feature flag

## Open Questions / Next Steps
- Alice to share wireframes by Friday
- Bob to estimate API effort by end of day
```

## Next Step
`Plans/step-05-output.md` — implement `output.py` and `--output-test` flag
