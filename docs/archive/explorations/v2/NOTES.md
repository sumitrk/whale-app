# V2 Notes

## Local LLM Post-Processing

Add a local LLM option for post-processing transcripts (cleanup, grammar, rephrasing)
instead of / alongside the current Anthropic API option.

### Why
- Works fully offline — no API key needed
- Sub-500ms inference on M2+ makes it nearly imperceptible after transcription
- Coexists with any Whisper model even on 8GB machines

### Recommended Model Lineup (Q4_K_M quantization)

| Model         | Size   | RAM    | Speed (M2+) | Quality    | Use Case                              |
|---------------|--------|--------|-------------|------------|---------------------------------------|
| Qwen 3 0.6B   | ~0.4GB | ~1GB   | <0.5s       | Good       | **Default** — ultra-fast, tiny        |
| Qwen 3.5 0.8B | ~0.5GB | ~1.2GB | <0.5s       | High       | Better quality, still tiny            |
| Gemma 3 1B    | ~0.7GB | ~1.5GB | ~0.5s       | High       | Strong grammar/spelling cleanup       |
| Llama 3.2 3B  | ~1.8GB | ~2.5GB | ~1-2s       | Very High  | Balanced quality/speed                |
| Phi-4-mini 3.8B | ~2.2GB | ~3GB | ~1-2s       | Very High  | Complex rephrasing, formal writing    |

### Recommendation
Default to **Qwen 3 0.6B (Q4_K_M)** — smallest footprint, fastest, coexists with
any Whisper model even on 8GB machines. Offer Qwen 3.5 0.8B and Gemma 3 1B as
quality upgrades. Keep Phi-4-mini / Llama 3.2 3B as "full quality" options for
users with 16GB+ RAM.

### Implementation Notes
- Use `mlx-lm` (already a dependency via mlx) to run these models locally
- Add a "Local LLM" option in AI Settings alongside the existing Anthropic API provider
- Models downloaded on-demand to `~/.cache/huggingface/hub/` (same as Whisper)
- Prompt: clean up transcript grammar/punctuation without changing meaning
