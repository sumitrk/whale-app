"""Put Bark's weights into NVIDIA's Parakeet TDT v3 NeMo model.

Bark ships transformers ParakeetForTDT names. NeMo uses the same layouts (channels-first
convs, separate LSTM biases), so only the names change. The renames are Underdog's own
transformers -> mlx-audio list from bark_mlx.py, which already speaks NeMo's names; the
layout changes it makes for MLX (transposed convs, fused LSTM bias) are not needed here.
"""
import re
import sys

import numpy as np
import torch

RENAMES = [
    (r"encoder\.subsampling\.layers\.", "encoder.pre_encode.conv."), (r"encoder\.subsampling\.linear\.", "encoder.pre_encode.out."),
    (r"\.conv\.norm\.", ".conv.batch_norm."), (r"\.q_proj\.", ".linear_q."), (r"\.k_proj\.", ".linear_k."),
    (r"\.v_proj\.", ".linear_v."), (r"\.o_proj\.", ".linear_out."), (r"\.relative_k_proj\.", ".linear_pos."),
    (r"\.bias_u$", ".pos_bias_u"), (r"\.bias_v$", ".pos_bias_v"), (r"^decoder\.embedding\.", "decoder.prediction.embed."),
    (r"^encoder_projector\.", "joint.enc."), (r"^decoder\.decoder_projector\.", "joint.pred."), (r"^joint\.head\.", "joint.joint_net.2."),
    (r"^decoder\.lstm\.", "decoder.prediction.dec_rnn.lstm."),
]


def to_nemo_names(sd):
    out = {}
    for k, v in sd.items():
        if k.endswith("num_batches_tracked") or k.startswith("vad_head"):
            continue
        for pat, rep in RENAMES:
            k = re.sub(pat, rep, k)
        out[k] = v
    return out


def load_bark_into(asr_model, bark_dir):
    sys.path.insert(0, bark_dir)
    from bark_loader import load_state_dict  # Underdog's loader, read before use

    sd, _ = load_state_dict(f"{bark_dir}/model.bark", as_numpy=True)
    bark = to_nemo_names(sd)
    target = asr_model.state_dict()
    # The preprocessor's window and mel filterbank are fixed buffers, not learned; Bark keeps
    # v3's feature settings, so NeMo's own are the right ones.
    missing = [k for k in target if k not in bark and not k.endswith("num_batches_tracked")
               and not k.startswith("preprocessor.")]
    unexpected = [k for k in bark if k not in target]
    shape_mismatch = [(k, bark[k].shape, tuple(target[k].shape)) for k in bark
                      if k in target and tuple(bark[k].shape) != tuple(target[k].shape)]
    if missing or unexpected or shape_mismatch:
        raise SystemExit(f"name/shape mismatch\n missing {missing[:10]} ({len(missing)})\n"
                         f" unexpected {unexpected[:10]} ({len(unexpected)})\n shapes {shape_mismatch[:10]}")
    new = {k: torch.from_numpy(np.ascontiguousarray(v)).to(target[k].dtype) for k, v in bark.items()}
    changed = sum(not torch.equal(new[k], target[k]) for k in new)
    asr_model.load_state_dict({**target, **new}, strict=True)
    return len(new), changed, bark
