# S1-mini by Superwhisper

Whale's optional Cleanup stage runs [S1-mini by Superwhisper](https://huggingface.co/superwhisper/s1-mini),
loaded from the MLX 8-bit conversion at `mlx-community/S1-mini-MLX-8bit`.

Whale does **not** redistribute the weights. They are downloaded from Hugging Face onto the
user's Mac, on request, from the Models settings pane — so the Apache 2.0 redistribution
obligations do not attach to the app binary. The `LICENSE` and `NOTICE` here are kept
verbatim anyway, because the licence's ADDITIONAL TERM binds *use and integration*, not only
redistribution:

> any use, distribution, or integration of this model, whether unmodified or as part of a
> derivative work or product, must continue to identify it by its original name, "S1-mini"
> by "Superwhisper", using that exact capitalization

That name is carried in the UI by `S1ModelCatalog.displayName`, which the Models pane shows
on the download row and repeats in the section footer. It is a licence term rather than a
copy decision: do not shorten it, retitle it, or fold it into a Whale-branded label.

If Whale ever ships the weights inside the app bundle, this folder has to be bundled with
them and the Apache 2.0 notice requirements revisited.
