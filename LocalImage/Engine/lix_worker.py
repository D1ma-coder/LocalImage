"""LocalImage engine worker.

A thin, stable bridge between the macOS app and mflux (MLX). The app starts one
process per job:

    python -I lix_worker.py families
    python -I lix_worker.py generate '<json>'
    python -I lix_worker.py quantize '<json>'

Events are JSON lines written to the ORIGINAL stdout. Everything mflux, tqdm or
any library prints is redirected to stderr, which the app keeps as a log. So the
event channel can never be corrupted by third-party output.

Cancellation: SIGINT. mflux turns a KeyboardInterrupt inside the denoising loop
into StopImageGenerationException; outside the loop we catch it ourselves.
"""

from __future__ import annotations

import json
import os
import signal
import sys
import time
import traceback

ENGINE_PROTOCOL = 4

# ---------------------------------------------------------------- event channel
_EVENT_FD = os.dup(1)
os.dup2(2, 1)  # anything printed from now on goes to stderr (the log)
sys.stdout = sys.stderr
_events = os.fdopen(_EVENT_FD, "w", buffering=1, encoding="utf-8")


class WorkerError(RuntimeError):
    """An error the app shows to the user: `code` selects the localized text there, the message is the English fallback."""

    def __init__(self, code: str, message: str, **params):
        super().__init__(message)
        self.code = code
        self.params = params


def emit(event: str, **payload) -> None:
    payload["event"] = event
    _events.write(json.dumps(payload, ensure_ascii=False) + "\n")
    _events.flush()


# ---------------------------------------------------------------- cancellation
_cancelled = False


def _on_sigint(signum, frame):  # noqa: ARG001
    global _cancelled
    _cancelled = True
    raise KeyboardInterrupt


signal.signal(signal.SIGINT, _on_sigint)
signal.signal(signal.SIGTERM, _on_sigint)


def _watch_parent() -> None:
    """Exit if the app dies: an orphaned worker would hold GBs of unified memory."""
    import threading

    parent = os.getppid()

    def loop():
        while True:
            time.sleep(2)
            if os.getppid() != parent:
                os._exit(3)

    threading.Thread(target=loop, daemon=True, name="parent-watch").start()


_watch_parent()

# ---------------------------------------------------------------- families
# registry key -> generate CLI module. Only text-to-image capable entries are listed;
# all of them also accept an init image (img2img) when mflux supports it for the family.
FAMILIES: dict[str, str] = {
    "z-image-turbo": "mflux.models.z_image.cli.z_image_turbo_generate",
    "z-image": "mflux.models.z_image.cli.z_image_generate",
    "flux2-klein-4b": "mflux.models.flux2.cli.flux2_generate",
    "flux2-klein-9b": "mflux.models.flux2.cli.flux2_generate",
    "flux2-klein-base-4b": "mflux.models.flux2.cli.flux2_generate",
    "flux2-klein-base-9b": "mflux.models.flux2.cli.flux2_generate",
    "flux3-image-klein": "mflux.models.flux3.cli.flux3_generate",
    "flux3-image-klein-base": "mflux.models.flux3.cli.flux3_generate",
    "krea-2": "mflux.models.krea2.cli.krea2_generate",
    "qwen-image": "mflux.models.qwen.cli.qwen_image_generate",
    "qwen-image-2.1": "mflux.models.qwen21.cli.qwen21_generate",
    "qwen-image-2.1-turbo": "mflux.models.qwen21.cli.qwen21_generate",
    "schnell": "mflux.models.flux.cli.flux_generate",
    "dev": "mflux.models.flux.cli.flux_generate",
    "krea-dev": "mflux.models.flux.cli.flux_generate",
    "iris-3b": "mflux.models.iris.cli.iris_generate",
    "anima-turbo": "mflux.models.anima.cli.anima_generate",
    "anima-aesthetic": "mflux.models.anima.cli.anima_generate",
    "ernie-image-turbo": "mflux.models.ernie_image.cli.ernie_image_turbo_generate",
    "ernie-image": "mflux.models.ernie_image.cli.ernie_image_generate",
    "boogu-image-turbo": "mflux.models.boogu.cli.boogu_image_generate",
    "lens-turbo": "mflux.models.lens.cli.lens_generate",
    "moss-image-sft": "mflux.models.moss_image.cli.moss_image_generate",
    "fibo2": "mflux.models.fibo2.cli.fibo2_generate",
    "ming-image-design": "mflux.models.ming_image.cli.ming_image_generate",
}

# Families whose checkpoints also edit from reference images: registry key -> (edit CLI module,
# how many references it takes). With images attached these run the edit CLI instead of img2img.
_FLUX2_EDIT = ("mflux.models.flux2.cli.flux2_edit_generate", 4)
_FLUX3_EDIT = ("mflux.models.flux3.cli.flux3_edit_generate", 10)
_QWEN21_EDIT = ("mflux.models.qwen21.cli.qwen21_edit_generate", 10)
EDIT_FAMILIES: dict[str, tuple[str, int]] = {
    "flux2-klein-4b": _FLUX2_EDIT,
    "flux2-klein-9b": _FLUX2_EDIT,
    "flux2-klein-base-4b": _FLUX2_EDIT,
    "flux2-klein-base-9b": _FLUX2_EDIT,
    "flux3-image-klein": _FLUX3_EDIT,
    "flux3-image-klein-base": _FLUX3_EDIT,
    "qwen-image-2.1": _QWEN21_EDIT,
    "qwen-image-2.1-turbo": _QWEN21_EDIT,
}


def download_patterns(cli_module: str) -> list[str]:
    """Union of the HF allow-patterns of a family's main weight definitions."""
    import importlib
    import inspect
    import pkgutil

    family_dir = cli_module.split(".")[2]
    patterns: list[str] = []
    try:
        package = importlib.import_module(f"mflux.models.{family_dir}.weights")
        for info in pkgutil.iter_modules(package.__path__):
            module = importlib.import_module(f"{package.__name__}.{info.name}")
            for name, obj in vars(module).items():
                if not (inspect.isclass(obj) and obj.__module__ == module.__name__):
                    continue
                if not hasattr(obj, "get_download_patterns"):
                    continue
                if any(skip in name for skip in ("Controlnet", "Redux", "NoTextEncoder", "Small")):
                    continue
                try:
                    for pattern in obj.get_download_patterns():
                        if pattern not in patterns:
                            patterns.append(pattern)
                except TypeError:
                    continue
    except Exception as exc:  # noqa: BLE001
        emit("log", message=f"patterns for {family_dir}: {exc!r}")
    return patterns


def cmd_families(_: dict) -> None:
    import importlib.metadata as md

    from mflux.cli.capabilities import describe_command
    from mflux.cli.defaults.defaults import GUIDANCE_SCALE, MODEL_INFERENCE_STEPS
    from mflux.models.common.config.model_config import AVAILABLE_MODELS

    described: dict[str, dict] = {}
    result = []
    for key, module in FAMILIES.items():
        if module not in described:
            described[module] = describe_command(module.rsplit(".", 1)[-1], module)
        entry = described[module]
        options = {o["flag"]: o.get("status", "honored") for o in entry.get("options", [])}
        traits = entry.get("traits", {})
        config = AVAILABLE_MODELS.get(key)
        result.append(
            {
                "key": key,
                "repo": config.model_name if config else None,
                "defaultSteps": MODEL_INFERENCE_STEPS.get(key, 25),
                "supportsGuidance": bool(config.supports_guidance) if config else False,
                "defaultGuidance": GUIDANCE_SCALE,
                "negativePrompt": options.get("--negative-prompt") in ("honored", "conditional"),
                "img2img": bool(traits.get("img2img")) and "--image" in options,
                "references": EDIT_FAMILIES[key][1] if key in EDIT_FAMILIES else 0,
                "lora": bool(traits.get("lora")),
                "computePrecision": "--compute-precision" in options
                and options.get("--compute-precision") != "ignored",
                "lowRam": "--low-ram" in options,
                "patterns": download_patterns(module),
            }
        )
    emit("families", mflux=md.version("mflux"), mlx=md.version("mlx"), protocol=ENGINE_PROTOCOL, families=result)


# ---------------------------------------------------------------- mixed quantization
# The app can ask for different bit widths for the text / vision-language encoder and
# for the image (diffusion transformer) part. mflux quantizes every component with one
# level, so we wrap its quantization step. Loading such a mixed save needs no patch:
# mflux reads each layer's stored precision back from the tensor shapes.

_IMAGE_HINTS = ("transformer", "controlnet", "heads", "connector")
_VAE_HINTS = ("vae", "decoder")


def component_role(name: str) -> str:
    lowered = name.lower()
    if any(h in lowered for h in _IMAGE_HINTS):
        return "image"
    if any(h in lowered for h in _VAE_HINTS):
        return "vae"
    return "text"


def install_mixed_quantization(text_bits: int | None, image_bits: int | None) -> None:
    import mlx.nn as nn

    from mflux.models.common.weights.loading.weight_applier import WeightApplier

    def bits_for(name: str, default: int) -> int | None:
        role = component_role(name)
        if role == "text" and text_bits is not None:
            return text_bits
        if role == "image" and image_bits is not None:
            return image_bits
        return default

    def _quantize(models, bits, components, weight_definition, weights=None):
        group_size = getattr(weight_definition, "quantization_group_size", 64)
        for name, model in models.items():
            component = components.get(name)
            component_weights = weights.components.get(name) if weights is not None else None
            if component is not None and component.weight_subkey is not None and component_weights is not None:
                component_weights = component_weights.get(component.weight_subkey, component_weights)
            if component and component.skip_quantization and component_weights is None:
                continue
            level = bits_for(name, bits)
            if level is None or level >= 16:
                continue
            predicate = WeightApplier._predicate_with_bits(weight_definition.quantization_predicate, level)
            if component_weights is not None:
                predicate = WeightApplier._stored_layer_predicate(component_weights, predicate)
            nn.quantize(model, group_size=group_size, class_predicate=predicate, bits=level)
            emit("log", message=f"quantized {name} ({component_role(name)}) to {level}-bit")

    original_single = WeightApplier.apply_and_quantize_single

    def apply_and_quantize_single(weights, model, component, quantize_arg, quantization_predicate=None):
        level = bits_for(component.name, quantize_arg)
        if level is not None and level >= 16:
            level = None
        return original_single(weights, model, component, level, quantization_predicate)

    WeightApplier._quantize = staticmethod(_quantize)
    WeightApplier.apply_and_quantize_single = staticmethod(apply_and_quantize_single)


# ---------------------------------------------------------------- previews
class PreviewCallback:
    """Decodes the current latents every N steps and hands a small JPEG to the app."""

    def __init__(self, model, latent_creator, out_dir: str, every: int, scale: float, max_side: int):
        self.model = model
        self.latent_creator = latent_creator
        self.out_dir = out_dir
        self.every = max(1, every)
        self.scale = scale
        self.max_side = max_side
        self.enabled = every > 0
        self.failures = 0
        self.started = time.time()
        os.makedirs(out_dir, exist_ok=True)

    def call_before_loop(self, seed, prompt, latents, config, canny_image=None, depth_image=None, control_images=None):
        self.started = time.time()
        self.previous = latents
        self.failures = 0
        emit(
            "denoise",
            start=int(config.init_time_step),
            total=int(config.num_inference_steps),
            width=int(config.width),
            height=int(config.height),
        )

    def call_in_loop(self, t, seed, prompt, latents, config, time_steps, denoised=None):
        import mlx.core as mx

        global _cancelled
        # mflux evaluates lazily right after this callback; forcing it here costs nothing extra
        # and lets progress report the moment the step is really done, before any preview work.
        mx.eval(latents)
        step = int(t) + 1
        total = int(config.num_inference_steps)
        emit("step", step=step, total=total, elapsed=round(time.time() - self.started, 3))
        if _cancelled:
            raise KeyboardInterrupt
        last = step >= total
        due = step % self.every == 0 or step == int(config.init_time_step) + 1
        if self.enabled and self.failures < 3 and not last and due:
            try:
                estimate = denoised if denoised is not None else self._estimate_clean(t, latents, config)
                path = self._decode(estimate, config, step)
                self.failures = 0
                emit("preview", step=step, path=path)
            except Exception as exc:  # noqa: BLE001 - a preview must never kill a generation
                self.failures += 1
                emit("log", message=f"preview failed ({self.failures}/3): {exc!r}")
        self.previous = latents
        if _cancelled:
            raise KeyboardInterrupt

    def call_after_loop(self, seed, prompt, latents, config):
        emit("phase", phase="decoding")

    def _estimate_clean(self, t, latents, config):
        """x̂0 for flow-matching samplers: the noisy x_t is pure noise early on, the estimate is not.

        x_next = x_prev + (σ_next − σ_prev)·v  →  v = Δx/Δσ,  x̂0 = x_next − σ_next·v
        """
        previous = getattr(self, "previous", None)
        try:
            sigmas = config.scheduler.sigmas
            sigma_prev = float(sigmas[int(t)].item())
            sigma_next = float(sigmas[int(t) + 1].item())
        except Exception:  # noqa: BLE001
            return latents
        if previous is None or previous.shape != latents.shape or abs(sigma_next - sigma_prev) < 1e-6:
            return latents
        velocity = (latents - previous) / (sigma_next - sigma_prev)
        return latents - sigma_next * velocity

    def _creators(self):
        """The creator mflux handed us first, then every other unpacker of the same family.

        Some families register a creator whose unpack does not match the variant actually
        running (Qwen-Image 2.1), so we try siblings and keep the first that decodes.
        """
        if getattr(self, "_working_creator", None) is not None:
            return [self._working_creator]
        import importlib
        import inspect
        import pkgutil

        found = [self.latent_creator]
        family_module = type(self.model).__module__.split(".")
        if len(family_module) > 2:
            try:
                package = importlib.import_module(".".join(family_module[:3]) + ".latent_creator")
                for info in pkgutil.iter_modules(package.__path__):
                    module = importlib.import_module(f"{package.__name__}.{info.name}")
                    for _, obj in inspect.getmembers(module, inspect.isclass):
                        if hasattr(obj, "unpack_latents") and obj not in found:
                            found.append(obj)
            except Exception:  # noqa: BLE001
                pass
        return found

    def _decode(self, latents, config, step: int) -> str:
        import mlx.core as mx

        from mflux.models.common.vae.vae_util import VAEUtil
        from mflux.utils.image_util import ImageUtil

        vae = getattr(self.model, "vae", None)
        errors = []
        decoded = None
        for creator in self._creators():
            try:
                unpacked = creator.unpack_latents(latents=latents, height=config.height, width=config.width)
                if self.scale < 1.0 and unpacked.ndim >= 4 and unpacked.shape[-1] >= 32 and unpacked.shape[-2] >= 32:
                    # 2×2 mean pool of the clean estimate: 4× cheaper decode, no aliasing
                    h, w = unpacked.shape[-2] // 2, unpacked.shape[-1] // 2
                    lead = tuple(unpacked.shape[:-2])
                    unpacked = unpacked[..., : h * 2, : w * 2].reshape(*lead, h, 2, w, 2).mean(axis=(-3, -1))
                channels = getattr(vae, "latent_channels", None)
                if vae is None:
                    decoded = unpacked  # pixel-space models (Iris)
                elif hasattr(vae, "decode_packed_latents") and channels and unpacked.shape[1] > channels:
                    decoded = vae.decode_packed_latents(unpacked)
                else:
                    decoded = VAEUtil.decode(vae, unpacked.astype(mx.float32), None)
                if decoded.ndim == 5:
                    decoded = decoded[:, :, 0]
                mx.eval(decoded)
                self._working_creator = creator
                break
            except Exception as exc:  # noqa: BLE001
                errors.append(f"{getattr(creator, '__name__', creator)}: {exc!r}")
                decoded = None
        if decoded is None:
            raise RuntimeError("; ".join(errors) or "no decoder")
        image = ImageUtil.to_pil(decoded)
        image.thumbnail((self.max_side, self.max_side))
        path = os.path.join(self.out_dir, f"step_{step:03d}.jpg")
        image.convert("RGB").save(path, quality=85)
        del decoded
        return path


def install_callbacks(preview_options: dict) -> None:
    from mflux.callbacks import callback_manager as cm

    original = cm.CallbackManager.register_callbacks

    def register_callbacks(args, model, latent_creator, *a, **kw):
        result = original(args, model, latent_creator, *a, **kw)
        model.callbacks.register(
            PreviewCallback(
                model=model,
                latent_creator=latent_creator,
                out_dir=preview_options["dir"],
                every=int(preview_options.get("every", 1)),
                scale=float(preview_options.get("scale", 0.5)),
                max_side=int(preview_options.get("maxSide", 768)),
            )
        )
        emit("phase", phase="encoding")
        return result

    cm.CallbackManager.register_callbacks = staticmethod(register_callbacks)
    # CLI modules imported `CallbackManager` by name; they share the class object, so the
    # patched staticmethod is visible to them as well.


# ---------------------------------------------------------------- generate
def build_generate_argv(job: dict) -> list[str]:
    argv = [
        "lix",
        "--model",
        job["modelPath"],
        "--base-model",
        job["family"],
        "--prompt",
        job["prompt"],
        "--width",
        str(job["width"]),
        "--height",
        str(job["height"]),
        "--seed",
        *[str(seed) for seed in job["seeds"]],
        "--output",
        job["output"],
    ]
    caps = job.get("caps", {})
    if job.get("steps"):
        argv += ["--steps", str(job["steps"])]
    if job.get("guidance") is not None and caps.get("supportsGuidance"):
        argv += ["--guidance", str(job["guidance"])]
    if job.get("negativePrompt") and caps.get("negativePrompt"):
        argv += ["--negative-prompt", job["negativePrompt"]]
    if job.get("referencePaths"):
        argv += ["--image-paths", *job["referencePaths"]]
    elif job.get("imagePath") and caps.get("img2img"):
        argv += ["--image", job["imagePath"], str(job.get("imageStrength", 0.4))]
    if job.get("quantize"):
        argv += ["--quantize", str(job["quantize"])]
    if job.get("lowRam") and caps.get("lowRam", True):
        argv += ["--low-ram"]
    if job.get("computePrecision") and caps.get("computePrecision"):
        argv += ["--compute-precision", job["computePrecision"]]
    if job.get("mlxCacheLimitGB"):
        argv += ["--mlx-cache-limit-gb", str(job["mlxCacheLimitGB"])]
    if job.get("vaeTiling"):
        argv += ["--vae-tiling"]
    for lora in job.get("loras", []) or []:
        argv += ["--lora", lora["path"], str(lora.get("scale", 1.0))]
    if job.get("metadata", True):
        argv += ["--metadata"]
    argv += ["--battery-percentage-stop-limit", str(job.get("batteryStop", 5))]
    return argv


def install_image_hook() -> list[str]:
    from mflux.utils.generated_image import GeneratedImage

    saved: list[str] = []
    original = GeneratedImage.save

    def save(self, path, *args, **kwargs):
        result = original(self, path, *args, **kwargs)
        final = str(path)
        saved.append(final)
        emit("image", path=final, seed=getattr(self, "seed", None), seconds=getattr(self, "generation_time", None))
        return result

    GeneratedImage.save = save
    return saved


def cmd_generate(job: dict) -> None:
    started = time.time()
    emit("phase", phase="starting")
    import importlib

    import mlx.core as mx

    if job.get("hfToken"):
        os.environ["HF_TOKEN"] = job["hfToken"]
    family = job["family"]
    module_name = FAMILIES.get(family)
    if module_name is None:
        raise WorkerError("unsupported_family", f"Model family '{family}' is not supported", family=family)
    if job.get("referencePaths"):
        if family not in EDIT_FAMILIES:
            raise WorkerError("unsupported_family", f"Model family '{family}' does not edit from references", family=family)
        module_name, limit = EDIT_FAMILIES[family]
        job["referencePaths"] = job["referencePaths"][:limit]

    if job.get("textBits") or job.get("imageBits"):
        install_mixed_quantization(job.get("textBits"), job.get("imageBits"))
        if not job.get("quantize"):
            job["quantize"] = job.get("imageBits") or job.get("textBits")
    install_callbacks(job.get("preview", {"dir": os.path.dirname(job["output"]), "every": 1}))

    saved = install_image_hook()
    module = importlib.import_module(module_name)
    argv = build_generate_argv(job)
    emit("log", message="argv: " + " ".join(a if " " not in a else repr(a) for a in argv[1:]))
    emit("phase", phase="loading")
    sys.argv = argv
    try:
        module.main()
    except SystemExit as exc:
        if exc.code not in (0, None):
            raise WorkerError("generation_rejected", "mflux rejected the generation parameters (details in the log)") from None
    except KeyboardInterrupt:
        pass

    if _cancelled:
        emit("cancelled", images=saved)
        return
    if not saved:
        raise WorkerError("no_image", "Generation finished without an image (details in the log)")
    emit(
        "done",
        images=saved,
        seconds=round(time.time() - started, 2),
        peakMemoryGB=round(mx.get_peak_memory() / 1e9, 2),
    )


# ---------------------------------------------------------------- quantize (save)
def cmd_quantize(job: dict) -> None:
    emit("phase", phase="starting")
    if job.get("hfToken"):
        os.environ["HF_TOKEN"] = job["hfToken"]
    text_bits = job.get("textBits")
    image_bits = job.get("imageBits")
    install_mixed_quantization(text_bits, image_bits)
    from mflux.models.common.cli import save

    level = image_bits if image_bits and image_bits < 16 else text_bits
    argv = ["lix", "--model", job["source"], "--base-model", job["family"], "--path", job["destination"]]
    if level and level < 16:
        argv += ["--quantize", str(level)]
    emit("log", message="argv: " + " ".join(argv[1:]))
    emit("phase", phase="quantizing")
    sys.argv = argv
    try:
        save.main()
    except SystemExit as exc:
        if exc.code not in (0, None):
            raise WorkerError("save_failed", "mflux could not save the model (details in the log)") from None
    if _cancelled:
        emit("cancelled")
        return
    emit("done", path=job["destination"])


COMMANDS = {"families": cmd_families, "generate": cmd_generate, "quantize": cmd_quantize}


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        emit("error", message=f"usage: lix_worker.py {{{'|'.join(COMMANDS)}}} [json]")
        return 2
    payload = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
    try:
        COMMANDS[sys.argv[1]](payload)
        return 0
    except KeyboardInterrupt:
        emit("cancelled")
        return 130
    except BaseException as exc:  # noqa: BLE001
        traceback.print_exc()
        message = str(exc) or exc.__class__.__name__
        code = getattr(exc, "code", None)
        params = getattr(exc, "params", {})
        lowered = message.lower()
        if "out of memory" in lowered or "insufficient memory" in lowered or "[metal]" in lowered:
            code = "out_of_memory"
        emit("error", message=message, kind=exc.__class__.__name__, code=code, params=params)
        return 1


if __name__ == "__main__":
    sys.exit(main())
