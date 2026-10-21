"""Convert Bark (in NeMo's Parakeet v3 graph) into the four Core ML parts FluidAudio loads.

Follows FluidInference's own v3 exporter (mobius models/stt/parakeet-tdt-v3-0.6b/coreml,
96874b2b): same wrappers, same 15 s window, same input and output names. Two differences:

- The Preprocessor is copied from FluidAudio's stock v3 folder. It holds no learned weights
  and Bark keeps v3's feature settings, so it's the same model.
- The encoder is palettized with one lookup table per output row, built from the values each
  row already has. Bark stores every encoder row as a handful of fp16 levels, so this is
  exact, not a k-means approximation: 3-bit tables for the big matrices, 6-bit for the small
  convs. Per-row tables need Core ML's macOS 15 opset, so that encoder is only built when
  BARK_TARGET=macOS15. The shipped encoder comes from encoder_variants.py instead.

  BARK_TARGET=macOS14 (default, Whale's deployment target) or macOS15
  python convert_bark.py <parakeet-v3.nemo> <bark-dir> <stock-v3-coreml-dir> <trace.wav> <out-dir>
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import coremltools as ct
import coremltools.optimize.coreml as cto
import nemo.collections.asr as nemo_asr
import numpy as np
import soundfile as sf
import torch

from bark_to_nemo import load_bark_into

nemo_path, bark_dir, stock_dir, trace_wav, out_dir = sys.argv[1:6]
stock_dir, out_dir = Path(stock_dir), Path(out_dir)
pkg_dir = out_dir / "mlpackage"
pkg_dir.mkdir(parents=True, exist_ok=True)
TARGET = {"macOS14": ct.target.macOS14, "macOS15": ct.target.macOS15}[os.environ.get("BARK_TARGET", "macOS14")]
MAX_SAMPLES = 240_000  # FluidAudio's 15 s window


class Encoder(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, mel, mel_length):
        return self.m(audio_signal=mel, length=mel_length.to(torch.long))


class Decoder(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, targets, target_length, h_in, c_in):
        out, _, state = self.m(targets=targets.to(torch.long), target_length=target_length.to(torch.long),
                               states=[h_in, c_in])
        return out, state[0], state[1]


class JointDecision(torch.nn.Module):
    """Single step: encoder_step [1,1024,1] x decoder_step [1,640,1] -> token, prob, duration,
    plus the top-K candidates FluidAudio's v3 path reads for language filtering
    (JointDecisionv3, mobius JointDecisionSingleStep with K = 64)."""

    def __init__(self, joint, vocab_size, num_extra, top_k=64):
        super().__init__()
        self.joint = joint
        self.vocab_with_blank = vocab_size + 1
        self.num_extra = num_extra
        self.top_k = top_k

    def forward(self, encoder_step, decoder_step):
        x = self.joint.enc(encoder_step.transpose(1, 2)).unsqueeze(2) + self.joint.pred(decoder_step.transpose(1, 2)).unsqueeze(1)
        logits = self.joint.joint_net[2](self.joint.joint_net[0](x))
        tok_logits = logits[..., : self.vocab_with_blank]
        token_id = torch.argmax(tok_logits, dim=-1).to(torch.int32)
        token_prob = torch.gather(torch.softmax(tok_logits, dim=-1), -1, token_id.long().unsqueeze(-1)).squeeze(-1)
        duration = torch.argmax(logits[..., -self.num_extra:], dim=-1).to(torch.int32)
        top_k_logits, top_k_ids = torch.topk(tok_logits, k=self.top_k, dim=-1)
        return token_id, token_prob, duration, top_k_ids.to(torch.int32), top_k_logits


def convert(module, example, inputs, outputs, name):
    traced = torch.jit.trace(module, example, strict=False).eval()
    model = ct.convert(traced, convert_to="mlprogram", inputs=inputs, outputs=outputs,
                       minimum_deployment_target=TARGET, compute_units=ct.ComputeUnit.ALL)
    model.author = "Whale (from Underdog Bark 3.0 Clean, CC-BY-4.0)"
    return model


def palettize_per_row(model):
    """One LUT per output row, from the row's own values. In unique mode coremltools sizes each
    tensor's LUT to its fullest row (3 bits for Bark's 5- or 7-level rows, 6 for the 6-bit
    convs) and skips any tensor with more than 256 values in a row, so the result is exact."""
    config = cto.OpPalettizerConfig(mode="unique", granularity="per_grouped_channel", group_size=1,
                                    channel_axis=0, weight_threshold=4096)
    return cto.palettize_weights(model, cto.OptimizationConfig(global_config=config))


asr = nemo_asr.models.EncDecRNNTBPEModel.restore_from(nemo_path, map_location="cpu").eval()
count, changed, _ = load_bark_into(asr, bark_dir)
print(f"loaded {count} Bark tensors ({changed} differ from stock v3)")
asr.decoder._rnnt_export = True

wave, sr = sf.read(trace_wav, dtype="float32", always_2d=True)
assert sr == 16000
wave = np.pad(wave.mean(1), (0, max(0, MAX_SAMPLES - len(wave))))[:MAX_SAMPLES]
audio = torch.from_numpy(wave).unsqueeze(0)
audio_len = torch.tensor([MAX_SAMPLES], dtype=torch.int32)

with torch.inference_mode():
    mel, mel_len = asr.preprocessor(input_signal=audio, length=audio_len.long())
    enc, enc_len = asr.encoder(audio_signal=mel, length=mel_len)
mel, mel_len = mel.clone(), mel_len.to(torch.int32).clone()
enc = enc.clone()
print("mel", tuple(mel.shape), "encoder", tuple(enc.shape))

# The slow part, so both packages are kept and a rerun reuses them. The fp16 one is the
# input to encoder_variants.py.
encoder_fp16_pkg, encoder_pkg = pkg_dir / "Encoder-fp16.mlpackage", pkg_dir / "Encoder.mlpackage"
if not encoder_fp16_pkg.exists():
    convert(Encoder(asr.encoder.eval()), (mel, mel_len),
            [ct.TensorType(name="mel", shape=tuple(mel.shape), dtype=np.float32),
             ct.TensorType(name="mel_length", shape=(1,), dtype=np.int32)],
            [ct.TensorType(name="encoder", dtype=np.float32),
             ct.TensorType(name="encoder_length", dtype=np.int32)], "Encoder").save(str(encoder_fp16_pkg))
if TARGET == ct.target.macOS15 and not encoder_pkg.exists():
    palettize_per_row(ct.models.MLModel(str(encoder_fp16_pkg), skip_model_load=True)).save(str(encoder_pkg))

layers, hidden = int(asr.decoder.pred_rnn_layers), int(asr.decoder.pred_hidden)
targets = torch.full((1, 1), asr.decoder.blank_idx, dtype=torch.int32)
tlen = torch.tensor([1], dtype=torch.int32)
zero = torch.zeros(layers, 1, hidden)
decoder = convert(Decoder(asr.decoder.eval()), (targets, tlen, zero, zero),
                  [ct.TensorType(name="targets", shape=(1, 1), dtype=np.int32),
                   ct.TensorType(name="target_length", shape=(1,), dtype=np.int32),
                   ct.TensorType(name="h_in", shape=tuple(zero.shape), dtype=np.float32),
                   ct.TensorType(name="c_in", shape=tuple(zero.shape), dtype=np.float32)],
                  [ct.TensorType(name="decoder", dtype=np.float32),
                   ct.TensorType(name="h_out", dtype=np.float32),
                   ct.TensorType(name="c_out", dtype=np.float32)], "Decoder")
decoder.save(str(pkg_dir / "Decoder.mlpackage"))

with torch.inference_mode():
    dec, _, _ = Decoder(asr.decoder)(targets, tlen, zero, zero)
dec = dec.clone()
jd = JointDecision(asr.joint.eval(), int(asr.tokenizer.vocab_size), int(asr.joint.num_extra_outputs))
joint = convert(jd, (enc[:, :, :1].contiguous(), dec[:, :, :1].contiguous()),
                [ct.TensorType(name="encoder_step", shape=(1, enc.shape[1], 1), dtype=np.float32),
                 ct.TensorType(name="decoder_step", shape=(1, dec.shape[1], 1), dtype=np.float32)],
                [ct.TensorType(name="token_id", dtype=np.int32),
                 ct.TensorType(name="token_prob", dtype=np.float32),
                 ct.TensorType(name="duration", dtype=np.int32),
                 ct.TensorType(name="top_k_ids", dtype=np.int32),
                 ct.TensorType(name="top_k_logits", dtype=np.float32)], "JointDecisionv3")
joint.save(str(pkg_dir / "JointDecisionv3.mlpackage"))

# Compile into the folder layout FluidAudio expects, with the stock v3 Preprocessor and vocab.
for name in ("Encoder", "Decoder", "JointDecisionv3"):
    if not (pkg_dir / f"{name}.mlpackage").exists():
        continue
    target = out_dir / f"{name}.mlmodelc"
    shutil.rmtree(target, ignore_errors=True)
    subprocess.run(["xcrun", "coremlcompiler", "compile", str(pkg_dir / f"{name}.mlpackage"), str(out_dir)],
                   check=True, stdout=subprocess.DEVNULL)
for item in ("Preprocessor.mlmodelc", "config.json", "parakeet_v3_vocab.json", "parakeet_vocab.json"):
    src = stock_dir / item
    if src.is_dir():
        shutil.copytree(src, out_dir / item, dirs_exist_ok=True)
    elif src.exists():
        shutil.copy(src, out_dir / item)
json.dump({"source": "ConwayResearch/Underdog-Bark-3.0-Clean", "license": "CC-BY-4.0",
           "graph": "nvidia/parakeet-tdt-0.6b-v3 via NeMo", "encoder": "per-row LUT 3/6-bit, exact"},
          open(out_dir / "bark-conversion.json", "w"), indent=2)
print("done ->", out_dir)
