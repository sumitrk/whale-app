"""Build differently compressed Bark encoders, each as a complete FluidAudio v3 folder.

The per-row 3-bit encoder from convert_bark.py is exact but runs at half the speed of the
stock one, so this tries the other ways Core ML can hold the same weights:

  int8-row    per-row int8 linear. Near exact (each row's 5 levels rounded to 1/127 of its
              largest), iOS16 opset, so it also runs on macOS 14.
  lut6-tensor 6-bit k-means LUT per tensor: what FluidAudio ships for stock v3. Lossy for Bark,
              whose levels differ row to row. iOS16 opset.
  lut4-pair   one LUT per pair of rows: at most 10 values, so 4 bits and still exact. macOS 15.
  fp16        no compression, for reference.

  python encoder_variants.py <bark-coreml-dir> <variants-dir> [names...]
Needs <bark-coreml-dir>/mlpackage/Encoder-fp16.mlpackage, which convert_bark.py writes.
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

import coremltools as ct
import coremltools.optimize.coreml as cto

VARIANTS = {
    "int8-row": lambda m: cto.linear_quantize_weights(m, cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(
        mode="linear_symmetric", dtype="int8", granularity="per_channel", weight_threshold=4096))),
    "lut6-tensor": lambda m: cto.palettize_weights(m, cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(
        mode="kmeans", nbits=6, granularity="per_tensor", weight_threshold=4096, num_kmeans_workers=8))),
    "lut4-pair": lambda m: cto.palettize_weights(m, cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(
        mode="unique", granularity="per_grouped_channel", group_size=2, channel_axis=0, weight_threshold=4096))),
    "fp16": lambda m: m,
}

def main():
    bark_dir, out_root = Path(sys.argv[1]), Path(sys.argv[2])
    wanted = sys.argv[3:] or ["int8-row", "lut6-tensor", "lut4-pair", "fp16"]
    fp16 = bark_dir / "mlpackage" / "Encoder-fp16.mlpackage"
    for name in wanted:
        folder = out_root / name
        if (folder / "Encoder.mlmodelc").exists():
            print("skip", name)
            continue
        folder.mkdir(parents=True, exist_ok=True)
        print("building", name, flush=True)
        model = VARIANTS[name](ct.models.MLModel(str(fp16), skip_model_load=True))
        pkg = folder / "Encoder.mlpackage"
        model.save(str(pkg))
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(pkg), str(folder)], check=True, stdout=subprocess.DEVNULL)
        shutil.rmtree(pkg)
        for item in os.listdir(bark_dir):
            if item not in ("Encoder.mlmodelc", "mlpackage") and not (folder / item).exists():
                os.symlink((bark_dir / item).resolve(), folder / item)
        print("done", name, flush=True)


# k-means runs in worker processes that re-import this file, so the work must not run on import.
if __name__ == "__main__":
    main()
