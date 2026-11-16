# Changelog

## Unreleased

- Resolution follows the model: «Maximum» is the model's own limit, from 1 MP (Iris, ERNIE-Image) through 2K (Z-Image, FLUX.2 klein, Krea 2, Qwen-Image 2.1, Boogu, Fibo 2.0, Ming-Image) to 4K (FLUX 3 klein); «High» lies halfway, and levels a model can't reach are hidden. Model badges show the limit.
- Time estimates learn each stage from samples of its own size instead of one rate per model: steps against the output plus reference megapixels (references add tokens to every step: with two of them a FLUX 3 klein step took 4–8× longer), load against attached images (2 references added ≈ 7 s), decode against output size. New stages: the slower first step of a run and the worker's exit after the last image, which the estimate left out (it was usually short by 5–15 s). After the first step the run's own speed replaces history, and recent runs weigh more. Load time is no longer counted while waiting for a previous job.

## 1.2.0 — 2026-11-16

- Catalog: newest models first, by the release date of the original repo.
- Catalog: added FLUX 3 Image klein Base, Fibo 2.0 and Ming-Image Design.
- Catalog: models whose original repo is gated are shown when a ready MLX build is open to download (FLUX 3 Image klein, FLUX.2 klein 9B, Krea 2 Turbo, FLUX.1 schnell); the lock badge stays only for models without one.
- Model card summaries keep a leading rank such as "#1".
- Several attached images: FLUX.2 klein (up to 4), FLUX 3 klein and Qwen-Image 2.1 (up to 10) edit from reference images; other img2img models take one. The attachment no longer has a caption, and images a newly picked model can't use are removed.
- Installed models show the expected time of a standard image (1 MP, default steps) instead of seconds per step, from separately measured load, step and decode times.
- Removed the "Original + your own quantization" option: models are downloaded only as ready MLX builds, and Hugging Face search lists MLX builds (and catalog models). Models quantized earlier keep working.
- Settings → Load: limit the GPU load from 30% to 100% (the engine pauses after each step; applies to a running generation too, and time estimates account for it), and an option to lower the engine's CPU priority. The stored step speed excludes these pauses.

## 1.1.0 — 2026-11-16

- English interface. The app follows the system language: English or Russian. Every string, including errors from the engine, is localized.
- Releases are a `.dmg` disk image: drag LocalImage onto Applications.
- img2img: the progress and the time estimate count only the steps that actually run; the estimate before a run includes model loading and decoding.
- The parameters panel keeps a fixed width: typing, sliders and other changes no longer resize it or shift its content.
- Changing a parameter no longer rebuilds the window and toolbar; opening the sidebar no longer recreates its button.
- The parameters panel opens with a single animation.
- Switching to Studio no longer focuses or selects the prompt.
- Removed the progress bar under the canvas (the progress capsule and the step slots remain).

## 1.0.0 — 2026-11-15

- Native SwiftUI app for macOS 26+ on Apple Silicon with Liquid Glass; generation runs locally on mflux 0.24.0 / MLX in an isolated uv environment that the app installs itself.
- Studio: prompt, model switcher in the toolbar, format, quality, steps, count, seed, negative prompt for models that use it, and img2img with source influence.
- Live preview of every step as an x̂₀ estimate under a blur and loader; all slots of a batch are created up front; instant stop.
- Phase-aware remaining-time estimate that keeps counting between steps and learns load, step and decode times for each model on this Mac; img2img counts only the steps that actually run.
- Model catalog of open models with ready MLX builds; descriptions, licenses and statistics are loaded from Hugging Face.
- Hugging Face search with format, architecture, bit-width, compatibility and gated filters, author avatars and explained badges.
- Original weights with separate quantization of the text/VL encoder and the diffusion model, with combinations suggested for the memory of this Mac.
- Resumable sequential downloads over HTTP Range that continue after restarts.
- Memory estimate from Metal's working-set limit, float16 on M1/M2, automatic low-memory mode; works on 16 GB.
- Gallery with search, repeat with the same or a new seed, and `.lix.json` metadata next to every image.
- Hugging Face token in Settings, checked as you type and stored in a file with mode 600.
