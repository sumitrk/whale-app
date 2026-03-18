from __future__ import annotations

import collections
import threading
import time
import uuid
from pathlib import Path

import numpy as np
import sounddevice as sd
from scipy.io import wavfile

SAMPLE_RATE = 16_000
CHANNELS = 1
DTYPE = "int16"


def find_device_index(name: str) -> int:
    """Find input device index by partial name match."""
    devices = sd.query_devices()
    for i, device in enumerate(devices):
        if name.lower() in device["name"].lower() and device["max_input_channels"] > 0:
            return i

    print(f"\nERROR: Audio device '{name}' not found.")
    print("Available input devices:")
    for i, device in enumerate(devices):
        if device["max_input_channels"] > 0:
            print(f"  [{i}] {device['name']}")
    print(f"\nFix: Set AUDIO_DEVICE_NAME in .env to one of the names above.")
    print("Or install BlackHole and set up an Aggregate Device named 'MeetingAggregate'.")
    raise RuntimeError(f"Audio device '{name}' not found")


class Recorder:
    def __init__(self, device_name: str, chunk_duration_seconds: int):
        self._device_name = device_name
        self._chunk_duration = chunk_duration_seconds
        self._session_dir: Path | None = None
        self._stream: sd.InputStream | None = None
        self._writer_thread: threading.Thread | None = None
        self._stop_event = threading.Event()
        self._buffer: collections.deque = collections.deque()
        self._chunk_paths: list[Path] = []

    def start(self, session_id: str | None = None) -> None:
        session_id = session_id or str(uuid.uuid4())[:8]
        self._session_dir = Path(f"/tmp/transcribe-meetings/{session_id}")
        self._session_dir.mkdir(parents=True, exist_ok=True)
        self._chunk_paths = []
        self._stop_event.clear()

        device_index = find_device_index(self._device_name)
        print(f"Audio device: {sd.query_devices()[device_index]['name']} (index {device_index})")

        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype=DTYPE,
            device=device_index,
            callback=self._audio_callback,
        )

        self._writer_thread = threading.Thread(target=self._writer_loop, daemon=True)
        self._writer_thread.start()
        self._stream.start()

    def stop(self) -> list[Path]:
        """Stop recording. Returns sorted list of chunk WAV paths."""
        self._stop_event.set()
        if self._stream:
            self._stream.stop()
            self._stream.close()
            self._stream = None
        if self._writer_thread:
            self._writer_thread.join(timeout=10)
            self._writer_thread = None
        return sorted(self._chunk_paths)

    def cleanup(self) -> None:
        """Delete all temp chunk files for this session."""
        if self._session_dir and self._session_dir.exists():
            for f in self._session_dir.glob("*.wav"):
                f.unlink()
            try:
                self._session_dir.rmdir()
            except OSError:
                pass

    # ── Internal ──────────────────────────────────────────────────────────────

    def _audio_callback(
        self, indata: np.ndarray, frames: int, time_info, status
    ) -> None:
        if status:
            print(f"[audio] {status}", flush=True)
        self._buffer.append(indata.copy())

    def _writer_loop(self) -> None:
        chunk_samples = self._chunk_duration * SAMPLE_RATE
        accumulated: list[np.ndarray] = []
        total_frames = 0
        chunk_index = 1

        while not self._stop_event.is_set() or self._buffer:
            # Drain whatever is in the buffer
            while self._buffer:
                frames = self._buffer.popleft()
                accumulated.append(frames)
                total_frames += len(frames)

            # Flush when a full chunk is ready
            if total_frames >= chunk_samples:
                full_array = np.concatenate(accumulated, axis=0)
                self._write_chunk(full_array[:chunk_samples], chunk_index)
                leftover = full_array[chunk_samples:]
                accumulated = [leftover] if len(leftover) > 0 else []
                total_frames = len(leftover)
                chunk_index += 1

            time.sleep(0.01)

        # Flush final partial chunk (always, even if very short)
        if accumulated:
            final = np.concatenate(accumulated, axis=0)
            if len(final) > 0:
                self._write_chunk(final, chunk_index)

    def _write_chunk(self, audio: np.ndarray, chunk_index: int) -> None:
        audio_mono = audio.flatten()  # (N, 1) → (N,) for mono
        path = self._session_dir / f"chunk_{chunk_index:03d}.wav"
        wavfile.write(str(path), SAMPLE_RATE, audio_mono)
        self._chunk_paths.append(path)
        size_kb = path.stat().st_size // 1024
        print(f"  Saved chunk {chunk_index}: {path.name} ({size_kb} KB)", flush=True)
