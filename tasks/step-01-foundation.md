# Task: Step 1 — Config + Project Skeleton

## Status: COMPLETE ✅

## What Was Built
- `requirements.txt` — all dependencies
- `.gitignore` — ignores .env, __pycache__, *.wav, .DS_Store
- `.env.example` — template for user config
- `config.py` — loads .env, validates required keys, exits with clear errors
- `main.py` — minimal entry point that loads config and prints listening message

## What Worked
- Config validation exits with specific error messages for each missing key
- `VAULT_PATH` existence check works correctly
- Config dataclass loads all values correctly

## Issues Encountered & Fixed
- **`load_dotenv()` not overriding shell env vars**: The user's shell had `ANTHROPIC_API_KEY=` (empty string) set. `load_dotenv()` by default does NOT override existing env vars. Fixed by using `load_dotenv(override=True)` in `config.py`.
- **Vault path didn't exist**: Created `/Users/sumitkumar/Downloads/Meetings` as the vault path. The `.env` had this path but the directory wasn't created yet.

## Test Results
```
# Error path (no .env or missing key):
ERROR: VAULT_PATH is not set in .env
Fix: Add VAULT_PATH=<value> to your .env file

# Happy path:
Config loaded OK
  vault: /Users/sumitkumar/Downloads/Meetings
  audio: MeetingAggregate
  model: mlx-community/whisper-small-mlx
  chunk: 300s
```

## Current .env
```
VAULT_PATH=/Users/sumitkumar/Downloads/Meetings
ANTHROPIC_API_KEY=<set>
AUDIO_DEVICE_NAME=MeetingAggregate
WHISPER_MODEL=mlx-community/whisper-small-mlx
CHUNK_DURATION_SECONDS=300
```

## Next Step
`Plans/step-02-audio-recording.md` — implement `recorder.py` and `--record-test` flag
