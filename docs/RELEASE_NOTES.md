LocalImage 1.3.0

### Download

- `LocalImage-v1.3.0-macos-arm64.dmg` — macOS 26 or later, Apple Silicon. Open it and drag **LocalImage** onto **Applications**.

The app is not signed with a Developer ID and not notarized. After copying it, run `xattr -dr com.apple.quarantine /Applications/LocalImage.app` or click **Open Anyway** in System Settings → Privacy & Security. On first launch the app installs its engine (Python 3.12 + mflux 0.24.0 through uv) into `~/Library/Application Support/LocalImage`; models are downloaded separately from Hugging Face.

### Changes

- **Resolution by model.** Quality options follow each model's limit: up to 4K for FLUX 3 klein, 2K for Z-Image, FLUX.2 klein, Qwen-Image 2.1 and others, 1 MP for Iris and ERNIE-Image. Model cards show the limit.
- **More accurate time estimates**, including runs with attached images.

### Quick start

1. Open the `.dmg` and drag LocalImage onto Applications.
2. Launch it and install the engine when asked.
3. **Models → Catalog** → download Z-Image Turbo or FLUX.2 klein 4B.
4. **Studio** → type a prompt → **⌘↩**.

[README](https://github.com/D1ma-coder/LocalImage) · [Русский README](https://github.com/D1ma-coder/LocalImage/blob/main/README.ru.md) · [Changelog](https://github.com/D1ma-coder/LocalImage/blob/main/CHANGELOG.md)

Every model has its own license, shown in the catalog and on its Hugging Face page.
