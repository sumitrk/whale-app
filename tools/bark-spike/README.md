# Bark 3.0 Clean spike

Can Whale run [Underdog Bark 3.0 Clean](https://huggingface.co/ConwayResearch/Underdog-Bark-3.0-Clean)
(CC-BY-4.0, a Parakeet TDT 0.6B v3 fine-tune that drops "um", false starts and repeats) on its
existing FluidAudio / Core ML path, and is it better than today's Parakeet v2?

Answer: yes. Converted to Core ML it loads through FluidAudio 0.17.1's `AsrModels.loadLocal`
with `version: .v3`, runs as fast as today on short clips, and removes disfluencies far
better than Parakeet v2, with or without the S1-mini Cleanup step.

## Results (M4 Pro, 2026-10-21)

DisfluencySpeech test split: 250 clips of unscripted talk, 27 minutes. Word error rate after
Whisper's English normaliser (lower is better). "vs clean" scores against transcripts with
fillers, false starts and repeats removed; "vs verbatim" against every word.

| Model | vs clean % | vs verbatim % | 27 min of clips | Encoder on disk | Encoder zipped | macOS |
|---|--:|--:|--:|--:|--:|--:|
| Parakeet v2 (Whale today) | 12.62 | 2.88 | 11.7 s | 425 MB | 434 MB | 14 |
| Parakeet v2 + S1-mini Cleanup | 7.80 | 9.64 | 11.7 s + 35 s | +633 MB model | | 14 |
| Parakeet v3 (stock FluidAudio) | 13.11 | 2.75 | 12.2 s | 425 MB | | 14 |
| Bark Clean, Underdog's MLX script | 4.03 | 11.66 | 28.5 s | 1.25 GB in memory | 180 MB (`.bark`) | |
| **Bark Clean, Core ML, 6-bit LUT per tensor** | **3.93** | 11.06 | **12.7 s** | **425 MB** | **328 MB** | **14** |
| Bark Clean, Core ML, int8 per row | 3.66 | 11.29 | 12.9 s | 568 MB | 241 MB | 14 |
| Bark Clean, Core ML, 4-bit LUT per row pair (exact) | 3.72 | 11.34 | 16.6 s | 306 MB | | 15 |
| Bark Clean, Core ML, 3-bit LUT per row (exact) | 3.72 | 11.34 | 24.9 s | 237 MB | 215 MB | 15 |

Decoder, joint and preprocessor add 35 MB to every Bark folder.

26-minute real meeting (one file): v2 4.7 s, stock v3 8.2 s, Bark 6-bit 10.1 s. The v3 graph
is the bigger part of that gap (8,192-token vocabulary, top-K joint), not Bark. v2 left 6
"um"/"uh" in; Bark left none.

Memory: Core ML keeps the weights with the Neural Engine, outside the process, so the
harness's own footprint stays under 90 MB for every model and doesn't tell them apart. The
one measurable difference is S1-mini: about 1 GB resident while it cleans up, which Bark
makes unnecessary for removing fillers.

First load compiles for the Neural Engine once per model file: 10-14 s for the int8 and 6-bit
encoders, 30-70 s for the per-row LUT ones. After that, loading takes about 0.1 s.

## Things to know

- **Acronyms**: Bark sometimes spaces out letters ("P R", "U X"), as its training transcripts
  do: 4 to 7 times in the 26-minute meeting. v2 does it too on the test set ("T V"). A
  post-processing rule could join runs of single capitals.
- **Cleanup isn't a replacement for S1-mini** when you want styling, lists or email layout.
  Bark only removes disfluencies. It does make the S1 step optional for plain dictation.
- **English only**, like today's v2.
- `AsrModels.load(from:)` ignores the folder's own name: it resolves
  `<parent>/<FluidAudio's folder for that version>` and silently downloads the stock model if
  that folder isn't there. Custom weights need `loadLocal(from:)`.
- FluidAudio's v3 path needs the joint as `JointDecisionv3.mlmodelc`, with `top_k_ids` and
  `top_k_logits` outputs (K = 64).
- Bark's `model.bark` is entropy-coded and needs Underdog's Python loader (`constriction`), so
  the app can't read it directly. We would host the converted Core ML folder ourselves, with
  the attribution CC-BY requires (`work/models/bark-clean/NOTICE`).

## Reproduce

Everything heavy goes under `work/` (git-ignored, about 9 GB).

```bash
# environments (uv): MLX side on 3.12, NeMo + coremltools on 3.10 (scipy 1.14.1: 1.15's
# wheels don't load on macOS 27)
uv venv -p 3.12 work/venv-mlx && VIRTUAL_ENV=$PWD/work/venv-mlx uv pip install mlx mlx-audio mlx-lm constriction numpy soundfile soxr jiwer whisper-normalizer pyarrow
uv venv -p 3.10 work/venv-nemo && VIRTUAL_ENV=$PWD/work/venv-nemo uv pip install "nemo-toolkit[asr]==2.3.1" torch==2.7.0 coremltools==9.0b1 numpy==1.26.4 transformers==4.51.3 scipy==1.14.1 typer constriction soundfile soxr scikit-learn

# models and data
hf download ConwayResearch/Underdog-Bark-3.0-Clean --local-dir work/models/bark-clean
hf download nvidia/parakeet-tdt-0.6b-v3 parakeet-tdt-0.6b-v3.nemo --local-dir work/models/parakeet-v3-nemo
curl -L -o work/data/ds-test.parquet https://huggingface.co/datasets/amaai-lab/DisfluencySpeech/resolve/main/data/test-00000-of-00001.parquet
work/venv-mlx/bin/python prep_data.py work/data/ds-test.parquet work/data/ds

# reference run, conversion, variants
work/venv-mlx/bin/python run_mlx.py work/models/bark-clean work/data/ds work/out/bark-clean-mlx.jsonl
work/venv-nemo/bin/python check_nemo.py work/models/parakeet-v3-nemo/parakeet-tdt-0.6b-v3.nemo work/models/bark-clean work/data/ds work/out/bark-clean-mlx.jsonl
work/venv-nemo/bin/python convert_bark.py work/models/parakeet-v3-nemo/parakeet-tdt-0.6b-v3.nemo work/models/bark-clean \
  ~/Library/Application\ Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml work/data/trace-15s.wav work/models/bark-clean-coreml
work/venv-nemo/bin/python encoder_variants.py work/models/bark-clean-coreml work/models/variants

# Whale's own path (FluidAudio 0.17.1), then score
(cd harness && swift build -c release)
harness/.build/release/asr-bench work/models/variants/lut6-tensor v3-local work/data/ds work/out/bark-lut6-tensor.jsonl
harness/.build/release/asr-bench ~/Library/Application\ Support/Whale/Models/parakeet-tdt-0.6b-v2 v2 work/data/ds work/out/parakeet-v2-coreml.jsonl
work/venv-mlx/bin/python run_s1.py ~/Library/Application\ Support/Whale/Models/models/mlx-community/S1-mini-MLX-8bit work/out/parakeet-v2-coreml.jsonl work/out/parakeet-v2+s1.jsonl
work/venv-mlx/bin/python score.py work/data/ds/refs.jsonl work/out/*.jsonl
```

`work/data/trace-15s.wav` is the first 15 s of the DisfluencySpeech clips joined together. It
only sets the traced shapes.
