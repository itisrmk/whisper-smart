#!/usr/bin/env python3
"""Local speech-to-text sidecar for Whisper Smart on Linux.

This is the Linux counterpart to the macOS build's ``scripts/mlx_stt_infer.py``.
The protocol is deliberately the same shape — a resident daemon that loads the
model once and answers newline-delimited JSON requests — because that is what
makes dictation feel instant: the multi-second model load happens at startup,
not on the first word.

What changed from the macOS version is the engines underneath. MLX is Apple
Silicon only, so its ``parakeet-mlx`` and ``mlx-whisper`` packages are replaced
by:

  faster-whisper   CTranslate2 Whisper. Same model family as MLX Whisper,
                   runs on CUDA or CPU.
  parakeet         NVIDIA Parakeet TDT via ONNX Runtime (``onnx_asr``), so the
                   macOS default engine keeps working here.

Modes
-----
  --check                                    verify the engine imports (exit 0/1)
  --download --engine E --model REPO         prefetch weights into the HF cache
  --serve --engine E --model REPO            resident daemon, JSONL over stdio

Serve protocol (newline-delimited JSON)
---------------------------------------
  stdout, once the model is loaded and warmed:
      {"event": "ready", "device": "cuda"}

  request:  {"id": 1, "pcm": "<base64 int16 LE mono 16 kHz>"}
  response: {"id": 1, "text": "..."}  |  {"id": 1, "error": "..."}

  request:  {"cmd": "ping"}          ->  {"event": "pong"}
  EOF on stdin terminates the daemon.

Diagnostics go to stderr; stdout carries only protocol JSON.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import traceback

SAMPLE_RATE = 16_000


def log(message: str) -> None:
    """Diagnostics go to stderr so stdout stays pure protocol."""
    print(message, file=sys.stderr, flush=True)


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def fail(message: str, code: int = 1) -> "NoReturn":  # noqa: F821
    log(message)
    sys.exit(code)


# ---------------------------------------------------------------------------
# Audio helpers
# ---------------------------------------------------------------------------


def decode_pcm(encoded: str):
    """base64 int16 little-endian mono -> float32 numpy array in [-1, 1]."""
    import numpy as np

    raw = base64.b64decode(encoded)
    samples = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    return samples


# ---------------------------------------------------------------------------
# Device selection
# ---------------------------------------------------------------------------


def resolve_device(requested: str) -> str:
    """Turns the user's 'auto' | 'cuda' | 'cpu' preference into a real device.

    'auto' probes rather than assumes: a machine can have an NVIDIA GPU whose
    compute capability the installed CTranslate2/onnxruntime build does not
    cover, and falling back to a working CPU path beats failing outright.
    """
    if requested == "cpu":
        return "cpu"

    has_cuda = False
    try:
        import ctranslate2

        has_cuda = ctranslate2.get_cuda_device_count() > 0
    except Exception:
        # ctranslate2 is absent for the parakeet engine; fall back to probing
        # onnxruntime's provider list instead.
        try:
            import onnxruntime

            has_cuda = "CUDAExecutionProvider" in onnxruntime.get_available_providers()
        except Exception:
            has_cuda = False

    if requested == "cuda":
        if not has_cuda:
            log("CUDA was requested but no usable CUDA device was found; using CPU.")
            return "cpu"
        return "cuda"

    return "cuda" if has_cuda else "cpu"


# ---------------------------------------------------------------------------
# Engines
# ---------------------------------------------------------------------------


class FasterWhisperEngine:
    """CTranslate2 Whisper."""

    def __init__(self, model_id: str, device: str, language: str) -> None:
        from faster_whisper import WhisperModel

        # float16 is the point of using a GPU; int8 keeps CPU inference to a
        # sane speed on machines without one.
        compute_type = "float16" if device == "cuda" else "int8"
        try:
            self.model = WhisperModel(model_id, device=device, compute_type=compute_type)
        except Exception as exc:
            if device != "cuda":
                raise
            # A Blackwell/sm_120 card with an older CTranslate2 build lands
            # here. Retry on CPU rather than leaving the user with no engine.
            log(f"CUDA initialisation failed ({exc}); retrying on CPU.")
            device = "cpu"
            self.model = WhisperModel(model_id, device="cpu", compute_type="int8")

        self.device = device
        self.language = language or None

    def transcribe(self, samples) -> str:
        segments, _info = self.model.transcribe(
            samples,
            language=self.language,
            beam_size=1,
            vad_filter=False,
            condition_on_previous_text=False,
        )
        return "".join(segment.text for segment in segments).strip()


class ParakeetOnnxEngine:
    """NVIDIA Parakeet TDT through ONNX Runtime."""

    def __init__(self, model_id: str, device: str, language: str) -> None:
        import onnx_asr

        providers = (
            ["CUDAExecutionProvider", "CPUExecutionProvider"]
            if device == "cuda"
            else ["CPUExecutionProvider"]
        )
        try:
            self.model = onnx_asr.load_model(model_id, providers=providers)
        except Exception as exc:
            if device != "cuda":
                raise
            log(f"CUDA execution provider unavailable ({exc}); retrying on CPU.")
            device = "cpu"
            self.model = onnx_asr.load_model(model_id, providers=["CPUExecutionProvider"])

        self.device = device
        # Parakeet TDT does not take a language hint; the multilingual v3
        # model detects it, and v2 is English-only.
        self.language = language or None

    def transcribe(self, samples) -> str:
        return str(self.model.recognize(samples, sample_rate=SAMPLE_RATE)).strip()


ENGINES = {
    "faster-whisper": FasterWhisperEngine,
    "parakeet": ParakeetOnnxEngine,
}


def build_engine(engine: str, model_id: str, device: str, language: str):
    if engine not in ENGINES:
        fail(f"Unknown engine: {engine}")
    return ENGINES[engine](model_id, device, language)


# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------


def run_check(engine: str) -> None:
    """Verifies the engine's packages import, without loading any weights."""
    try:
        import numpy  # noqa: F401

        if engine == "faster-whisper":
            import faster_whisper  # noqa: F401
        elif engine == "parakeet":
            import onnx_asr  # noqa: F401
        else:
            fail(f"Unknown engine: {engine}")
    except Exception as exc:
        fail(f"Runtime import failed: {exc}")
    print("ok")


def run_download(engine: str, model_id: str) -> None:
    """Prefetches weights, emitting `PROGRESS <fraction>` lines on stdout.

    The Rust installer parses those lines to drive a real progress bar, exactly
    as the Swift installer does on macOS.
    """
    from huggingface_hub import snapshot_download

    tqdm_class = _make_progress_tqdm()
    kwargs = {"tqdm_class": tqdm_class} if tqdm_class is not None else {}

    if engine == "parakeet":
        # onnx_asr loads the ONNX graphs plus the tokeniser/config; the repos
        # also carry large unused artefacts, so fetch only what is needed.
        snapshot_download(
            repo_id=model_id,
            allow_patterns=["*.onnx", "*.json", "*.txt", "*.model", "*.onnx_data"],
            **kwargs,
        )
    else:
        snapshot_download(repo_id=model_id, **kwargs)

    # Guarantee the bar lands on 100% even if the last update was coalesced.
    print("PROGRESS 1.0000", flush=True)
    print("downloaded", flush=True)


def _make_progress_tqdm():
    """A tqdm subclass that reports aggregate download progress.

    huggingface_hub creates one bar per file plus an outer 'Fetching files'
    bar, so per-instance progress is meaningless. Byte totals are summed across
    every live instance to produce one overall fraction.
    """
    try:
        from tqdm.auto import tqdm as base_tqdm
    except Exception:
        return None

    class AggregateTqdm(base_tqdm):
        _live: "list[AggregateTqdm]" = []

        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            AggregateTqdm._live.append(self)

        def update(self, n=1):
            result = super().update(n)
            AggregateTqdm._emit()
            return result

        def close(self):
            result = super().close()
            AggregateTqdm._emit()
            return result

        @classmethod
        def _emit(cls) -> None:
            total = 0
            done = 0
            for bar in cls._live:
                # Only byte-denominated bars; the outer file-count bar would
                # skew the fraction badly on repos with one huge file.
                if bar.unit != "B" or not bar.total:
                    continue
                total += bar.total
                done += bar.n
            if total <= 0:
                return
            print(f"PROGRESS {min(done / total, 1.0):.4f}", flush=True)

    return AggregateTqdm


def run_serve(engine: str, model_id: str, device: str, language: str) -> None:
    log(f"loading {engine} model {model_id} on {device}...")
    try:
        runner = build_engine(engine, model_id, device, language)
    except Exception as exc:
        # A load failure must be reported on the protocol channel, not just as
        # a non-zero exit: the client is already waiting for "ready".
        emit({"event": "error", "error": f"Model load failed: {exc}"})
        log(traceback.format_exc())
        sys.exit(1)

    # Warm up on a short buffer of silence so the first real utterance does not
    # pay for lazy kernel compilation and graph optimisation.
    try:
        import numpy as np

        runner.transcribe(np.zeros(SAMPLE_RATE // 2, dtype=np.float32))
    except Exception as exc:
        log(f"warm-up failed (continuing): {exc}")

    emit({"event": "ready", "device": getattr(runner, "device", device)})
    log("ready")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            request = json.loads(line)
        except json.JSONDecodeError as exc:
            emit({"error": f"Malformed request: {exc}"})
            continue

        if request.get("cmd") == "ping":
            emit({"event": "pong"})
            continue

        request_id = request.get("id")
        encoded = request.get("pcm")
        if encoded is None:
            emit({"id": request_id, "error": "Request carried no audio."})
            continue

        try:
            samples = decode_pcm(encoded)
            text = runner.transcribe(samples)
            emit({"id": request_id, "text": text})
        except Exception as exc:
            # One bad utterance must not take the daemon down; the model is
            # still loaded and the next request can succeed.
            log(traceback.format_exc())
            emit({"id": request_id, "error": f"{type(exc).__name__}: {exc}"})

    log("stdin closed; exiting")


def main() -> None:
    parser = argparse.ArgumentParser(description="Whisper Smart STT sidecar")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--engine", default="faster-whisper", choices=sorted(ENGINES))
    parser.add_argument("--model", default="")
    parser.add_argument("--device", default="auto", choices=["auto", "cuda", "cpu"])
    parser.add_argument("--language", default="")
    args = parser.parse_args()

    # Keep every download inside the app's data directory so uninstalling
    # reclaims the weights instead of orphaning gigabytes in ~/.cache.
    if "HF_HOME" not in os.environ and "HF_HUB_CACHE" not in os.environ:
        log("HF_HUB_CACHE is not set; downloads will go to the default cache.")

    if args.check:
        run_check(args.engine)
        return

    if not args.model:
        fail("--model is required")

    if args.download:
        run_download(args.engine, args.model)
        return

    if args.serve:
        run_serve(args.engine, args.model, resolve_device(args.device), args.language)
        return

    fail("One of --check, --download, or --serve is required")


if __name__ == "__main__":
    main()
