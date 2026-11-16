LocalImage 1.2.0

### Download

- `LocalImage-v1.2.0-macos-arm64.dmg` — macOS 26 or later, Apple Silicon. Open it and drag **LocalImage** onto **Applications**.

The app is not signed with a Developer ID and not notarized. After copying it, run `xattr -dr com.apple.quarantine /Applications/LocalImage.app` or click **Open Anyway** in System Settings → Privacy & Security. On first launch the app installs its engine (Python 3.12 + mflux 0.24.0 through uv) into `~/Library/Application Support/LocalImage`; models are downloaded separately from Hugging Face.

### Changes

- **Several reference images.** FLUX.2 klein takes up to 4 attached images, FLUX 3 klein and Qwen-Image 2.1 up to 10, and edit from them; other img2img models take one. Images a newly picked model can't use are removed.
- **Load limit.** Settings → Load limits the GPU from 30% to 100%: the engine pauses after each step, so the Mac runs cooler and quieter. It applies to a running generation too, and time estimates account for it. A separate switch lowers the engine's CPU priority.
- **Time of a standard image.** Installed models show the expected time of a 1 MP image at default steps, built from separately measured load, step and decode times.
- **Catalog.** Newest models first; added FLUX 3 klein Base, Fibo 2.0 and Ming-Image Design; models with an open ready-made MLX build are shown even when the original repo is gated (FLUX 3 klein, FLUX.2 klein 9B, Krea 2 Turbo, FLUX.1 schnell).
- **Ready builds only.** The "Original + your own quantization" option is gone: models download as ready MLX builds, and Hugging Face search lists MLX builds and catalog models. Models quantized earlier keep working.

### Quick start

1. Open the `.dmg` and drag LocalImage onto Applications.
2. Launch it and install the engine when asked.
3. **Models → Catalog** → download Z-Image Turbo or FLUX.2 klein 4B.
4. **Studio** → type a prompt → **⌘↩**.

[README](https://github.com/D1ma-coder/LocalImage) · [Русский README](https://github.com/D1ma-coder/LocalImage/blob/main/README.ru.md) · [Changelog](https://github.com/D1ma-coder/LocalImage/blob/main/CHANGELOG.md)

Every model has its own license, shown in the catalog and on its Hugging Face page.
