# Bark 3.0 Clean by Underdog

Whale's "Bark 3.0 Clean" transcription model is
[Underdog Bark 3.0 Clean](https://huggingface.co/ConwayResearch/Underdog-Bark-3.0-Clean)
by Conway Research, a fine-tune of NVIDIA's parakeet-tdt-0.6b-v3 through Moondream's
parakeet-ultra. All three are licensed [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/).

Unlike S1-mini, Whale **does** redistribute these weights, in modified form: Underdog ships
`model.bark`, an entropy-coded format only their Python loader reads, so Whale downloads a
Core ML conversion we host ourselves (R2 bucket `whale-models`,
`bark-3.0-clean/v1/bark-3.0-clean-coreml-v1.tar.xz`). It was made by
`tools/bark-spike/convert_bark.py` and `encoder_variants.py` (`lut6-tensor`):

- `model.bark` unpacked exactly, then loaded into NVIDIA's Parakeet TDT 0.6B v3 graph in NeMo
- exported to Core ML (macOS 14 opset) in FluidAudio's v3 layout
- encoder weights palettized to a 6-bit lookup table per tensor, which is lossy:
  3.93% word errors against cleaned DisfluencySpeech transcripts, against 3.72% unpalettized
- Preprocessor and vocabulary taken from FluidAudio's stock v3 conversion

CC-BY asks for credit, a link to the licence, and a note that changes were made. The archive
carries `NOTICE` (this folder's copy is Underdog's, verbatim) and a README saying what
changed. In the app, the footer under the Models list credits Underdog Bark 3.0 Clean, says
it was converted, and links the model card and the licence (`ModelListSections`). Keep that
footer if the list is ever redesigned.
