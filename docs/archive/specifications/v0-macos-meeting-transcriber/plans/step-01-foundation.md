# Step 1: Config + Project Skeleton

## Goal
Get a runnable entry point that validates `.env` and exits with clear error messages on misconfiguration. Every subsequent step starts from a known-good state.

## What You're Building
- Project scaffolding (requirements, gitignore, env template)
- `config.py` — validates all required env vars, exits loudly on failure
- `main.py` — minimal entry point that loads config and stays alive

## What Is Usable After This Step
Running `python main.py` will tell you exactly what is wrong with your setup (missing keys, bad paths) or confirm everything is configured correctly.

---

## Files to Create

### `requirements.txt`
```
sounddevice
numpy
scipy
mlx-whisper
anthropic
pynput
python-dotenv
```

### `.gitignore`
```
.env
__pycache__/
*.pyc
*.wav
/tmp/
.DS_Store
```

### `.env.example`
```dotenv
# Path to your Obsidian vault or notes folder (must already exist)
VAULT_PATH=/Users/yourname/Documents/ObsidianVault/Meetings

# Anthropic API key
ANTHROPIC_API_KEY=sk-ant-...

# Name of the aggregate audio device in Audio MIDI Setup
AUDIO_DEVICE_NAME=MeetingAggregate

# Whisper model — use whisper-small-mlx during dev (fast, 150MB)
# Switch to mlx-community/whisper-large-v3-mlx for production quality
WHISPER_MODEL=mlx-community/whisper-large-v3-mlx

# Chunk duration in seconds (300 = 5 minutes)
CHUNK_DURATION_SECONDS=300
```

### `config.py`
```python
from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()


@dataclass
class Config:
    vault_path: Path
    anthropic_api_key: str
    audio_device_name: str
    whisper_model: str
    chunk_duration_seconds: int


def _require(key: str) -> str:
    value = os.getenv(key, "").strip()
    if not value:
        print(f"ERROR: {key} is not set in .env")
        print(f"Fix: Add {key}=<value> to your .env file")
        sys.exit(1)
    return value


def load_config() -> Config:
    vault_path = Path(_require("VAULT_PATH"))
    if not vault_path.exists():
        print(f"ERROR: VAULT_PATH does not exist: {vault_path}")
        print(f"Fix: Create the directory with: mkdir -p \"{vault_path}\"")
        sys.exit(1)
    if not vault_path.is_dir():
        print(f"ERROR: VAULT_PATH is not a directory: {vault_path}")
        sys.exit(1)

    api_key = _require("ANTHROPIC_API_KEY")
    audio_device = os.getenv("AUDIO_DEVICE_NAME", "MeetingAggregate").strip()
    whisper_model = os.getenv("WHISPER_MODEL", "mlx-community/whisper-large-v3-mlx").strip()

    chunk_str = os.getenv("CHUNK_DURATION_SECONDS", "300").strip()
    try:
        chunk_seconds = int(chunk_str)
    except ValueError:
        print(f"ERROR: CHUNK_DURATION_SECONDS must be an integer, got: {chunk_str}")
        sys.exit(1)

    return Config(
        vault_path=vault_path,
        anthropic_api_key=api_key,
        audio_device_name=audio_device,
        whisper_model=whisper_model,
        chunk_duration_seconds=chunk_seconds,
    )
```

### `main.py`
```python
from __future__ import annotations

import signal
import sys

from config import load_config


def main() -> None:
    config = load_config()

    print(f"Config loaded:")
    print(f"  Vault:        {config.vault_path}")
    print(f"  Audio device: {config.audio_device_name}")
    print(f"  Whisper model:{config.whisper_model}")
    print(f"  Chunk size:   {config.chunk_duration_seconds}s")
    print()
    print("Listening... Press ⌘⇧R to start recording.")
    print("(Hotkey not yet wired — press Ctrl+C to exit)")

    # Block until Ctrl+C
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    signal.pause()


if __name__ == "__main__":
    main()
```

---

## Install Dependencies

```bash
pip install -r requirements.txt
```

> Note: `mlx-whisper` requires Apple Silicon (M1/M2/M3/M4). Will not install on Intel Macs.

---

## Test: Error Path

```bash
# Run without a .env to see validation errors
python main.py
```

Expected output (if no .env):
```
ERROR: VAULT_PATH is not set in .env
Fix: Add VAULT_PATH=<value> to your .env file
```

## Test: Happy Path

```bash
# 1. Create your .env from the template
cp .env.example .env

# 2. Edit .env — set VAULT_PATH to a real folder and ANTHROPIC_API_KEY
#    Create the vault folder if needed:
mkdir -p ~/Documents/Meetings

# 3. Run
python main.py
```

Expected output:
```
Config loaded:
  Vault:        /Users/yourname/Documents/Meetings
  Audio device: MeetingAggregate
  Whisper model:mlx-community/whisper-large-v3-mlx
  Chunk size:   300s

Listening... Press ⌘⇧R to start recording.
(Hotkey not yet wired — press Ctrl+C to exit)
```

Press Ctrl+C → exits cleanly with code 0.

## Done When
- [ ] `python main.py` with missing `.env` exits with a specific, readable error
- [ ] `python main.py` with valid `.env` prints config summary and stays alive
- [ ] Ctrl+C exits cleanly

---
**Next:** `Plans/step-02-audio-recording.md`
