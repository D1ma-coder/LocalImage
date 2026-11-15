LocalImage 1.0.0

### Download

- `LocalImage-v1.0.0-macos-arm64.zip` — macOS 26 or later, Apple Silicon (`LocalImage.app`).

The app is not signed with a Developer ID and not notarized. After moving it to Applications, run `xattr -dr com.apple.quarantine /Applications/LocalImage.app` or click **Open Anyway** in System Settings → Privacy & Security. On first launch the app installs its engine (Python 3.12 + mflux 0.24.0 through uv) into `~/Library/Application Support/LocalImage`; models are downloaded separately from Hugging Face.

### Features

- Local image generation on mflux / MLX, designed to work on 16 GB of unified memory.
- Live preview of every step, batch slots created up front, instant stop and a remaining-time estimate that learns this Mac's speed.
- Model catalog with ready MLX builds and descriptions from Hugging Face; Hugging Face search with filters and explained badges.
- Original weights with separate quantization of the text encoder and the diffusion model.
- Resumable downloads, img2img, negative prompt where supported, gallery with search and repeat.

The interface is in Russian.

### Quick start

1. Unzip and move **LocalImage.app** to Applications.
2. Launch it and install the engine when asked.
3. **Модели → Каталог** → download Z-Image Turbo or FLUX.2 klein 4B.
4. **Студия** → type a prompt → **⌘↩**.

[README](https://github.com/D1ma-coder/LocalImage) · [Русский README](https://github.com/D1ma-coder/LocalImage/blob/main/README.ru.md) · [Changelog](https://github.com/D1ma-coder/LocalImage/blob/main/CHANGELOG.md)

Every model has its own license, shown in the catalog and on its Hugging Face page.
