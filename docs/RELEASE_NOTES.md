LocalImage 1.1.0

### Download

- `LocalImage-v1.1.0-macos-arm64.dmg` — macOS 26 or later, Apple Silicon. Open it and drag **LocalImage** onto **Applications**.

The app is not signed with a Developer ID and not notarized. After copying it, run `xattr -dr com.apple.quarantine /Applications/LocalImage.app` or click **Open Anyway** in System Settings → Privacy & Security. On first launch the app installs its engine (Python 3.12 + mflux 0.24.0 through uv) into `~/Library/Application Support/LocalImage`; models are downloaded separately from Hugging Face.

### Changes

- **English interface.** The app follows the system language: English or Russian. Every string, including engine errors, is localized.
- **Disk image.** Releases are now a `.dmg` instead of a `.zip`.
- **img2img progress.** The step counter and the remaining time count only the steps that actually run; the estimate before a run includes model loading and decoding.
- **Stable parameters panel.** Typing, sliders and other changes no longer resize the panel or shift its content; changing a parameter no longer rebuilds the window and toolbar.
- Smoother panel and sidebar animations, no automatic focus on the prompt when switching tabs, no progress bar under the canvas.

### Quick start

1. Open the `.dmg` and drag LocalImage onto Applications.
2. Launch it and install the engine when asked.
3. **Models → Catalog** → download Z-Image Turbo or FLUX.2 klein 4B.
4. **Studio** → type a prompt → **⌘↩**.

[README](https://github.com/D1ma-coder/LocalImage) · [Русский README](https://github.com/D1ma-coder/LocalImage/blob/main/README.ru.md) · [Changelog](https://github.com/D1ma-coder/LocalImage/blob/main/CHANGELOG.md)

Every model has its own license, shown in the catalog and on its Hugging Face page.
