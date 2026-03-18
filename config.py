from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(override=True)


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
        print(f'Fix: Create the directory with: mkdir -p "{vault_path}"')
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
