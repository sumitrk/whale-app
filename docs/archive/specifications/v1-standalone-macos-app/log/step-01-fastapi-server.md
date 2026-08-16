# Log: Step 01 — FastAPI Server

## Status: COMPLETE ✅

## What Was Built
- `server/server.py` — FastAPI app on `localhost:8765` with 4 endpoints
- `server/transcriber.py` — copy of root transcriber, adapted for server use
- `server/llm.py` — copy of root llm.py with `model` param added to `process_transcript`
- `server/requirements.txt` — FastAPI, uvicorn, python-multipart, pydantic + existing deps

## What Worked
- `GET /health` → `{"status":"ok","version":"1.0.0"}` ✅
- `GET /models` → lists 4 Whisper models, correctly detects whisper-small as downloaded ✅
- `POST /transcribe` with real WAV → returns transcript ✅
- `POST /summarise` with real transcript + API key → returns cleaned transcript + structured summary ✅

## Issues Encountered & Fixed
- **`pip` not found**: macOS Homebrew Python uses `pip3`, not `pip`. Used `pip3 --break-system-packages` to install into system Python (same env used by the project).
- **`process_transcript` signature mismatch**: Root `llm.py` only accepted `(transcript, api_key)`. Server version adds optional `model` param with default `claude-sonnet-4-6` to support model selection from Settings later.
- **Model cache detection**: The plan used a custom `MODEL_CACHE` path. The actual mlx-whisper uses HuggingFace cache at `~/.cache/huggingface/hub`. Fixed `/models` endpoint to check the correct HF path — correctly shows whisper-small-mlx as downloaded.

## Test Results
```
GET  /health    → {"status":"ok","version":"1.0.0"}
GET  /models    → 4 models, small=downloaded:true, rest=false
POST /transcribe → {"transcript":"Danke! Danke!","model":"..."} (background noise → correct)
POST /summarise  → {
  "cleaned_transcript": "Today we need to talk about the Q2 roadmap...",
  "summary": "## Topics Discussed\n- Q2 roadmap planning\n..."
}
```

## Next Step
`plans/step-02-swift-menubar-shell.md`
