#!/usr/bin/env python3
"""Local Parakeet runner for Whisper Smart.

This runner uses onnx-asr with the NVIDIA Parakeet TDT 0.6B v3 family
(`nemo-parakeet-tdt-0.6b-v3`) and supports:
  - one-shot inference
  - runtime/model check
  - persistent JSON-line worker mode
"""

from __future__ import annotations

import argparse
import atexit
import json
import shutil
import sys
from pathlib import Path
from typing import Dict, Optional, Sequence


PARAKEET_MODEL_ID = "nemo-parakeet-tdt-0.6b-v3"
CANONICAL_ENCODER = "encoder-model.int8.onnx"
CANONICAL_DECODER = "decoder_joint-model.int8.onnx"
CANONICAL_CONFIG = "config.json"
CANONICAL_NORMALIZER = "nemo128.onnx"
CANONICAL_VOCAB = "vocab.txt"


class RunnerError(RuntimeError):
    """Error that should be surfaced directly to the caller."""


def raise_dependency_error(module_name: str, exc: Exception) -> None:
    raise RunnerError(
        "DEPENDENCY_MISSING: Python package "
        f"'{module_name}' is required ({exc}). "
        "Runtime setup is automatic and still provisioning."
    )


def load_onnx_asr():
    try:
        import onnx_asr  # type: ignore
    except ModuleNotFoundError as exc:
        raise_dependency_error("onnx-asr", exc)
    except Exception as exc:
        raise RunnerError(f"DEPENDENCY_ERROR: Failed to import onnx_asr: {exc}") from exc
    return onnx_asr


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run local NVIDIA Parakeet inference.")
    parser.add_argument("--model", required=True, help="Path to local model alias file.")
    parser.add_argument("--audio", help="Path to mono 16 kHz WAV audio.")
    parser.add_argument(
        "--tokenizer",
        help="Optional tokenizer override path (tokenizer.model, tokenizer.json, or vocab.txt).",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Validate runtime/dependencies/model without running inference.",
    )
    parser.add_argument(
        "--serve",
        action="store_true",
        help="Run as a persistent JSON-line worker for repeated inference requests.",
    )

    args = parser.parse_args(argv)
    if args.check and args.serve:
        parser.error("--check and --serve are mutually exclusive")
    if not args.check and not args.serve and not args.audio:
        parser.error("--audio is required unless --check or --serve is used")
    return args


def ensure_file_exists(path: Path, label: str) -> None:
    if not path.exists():
        raise RunnerError(f"{label} not found: {path}")
    if not path.is_file():
        raise RunnerError(f"{label} is not a file: {path}")


def find_first_file(root: Path, names: Sequence[str]) -> Optional[Path]:
    for name in names:
        candidate = root / name
        if candidate.exists() and candidate.is_file():
            return candidate

    for name in names:
        matches = [p for p in root.rglob(name) if p.is_file()]
        if matches:
            matches.sort(key=lambda p: (len(p.parts), str(p)))
            return matches[0]

    return None


def copy_if_needed(source: Path, destination: Path) -> None:
    if source.resolve() == destination.resolve():
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def load_parakeet_model(onnx_asr, bundle_dir: Path):
    last_error: Optional[Exception] = None
    for quant in ("int8", None):
        try:
            return onnx_asr.load_model(
                PARAKEET_MODEL_ID,
                path=str(bundle_dir),
                quantization=quant,
                providers=["CPUExecutionProvider"],
            )
        except Exception as exc:
            last_error = exc

    details = str(last_error) if last_error is not None else "Unknown onnx-asr model load failure."
    raise RunnerError(
        "MODEL_LOAD_ERROR: Failed to initialize Parakeet onnx-asr model bundle. "
        f"Details: {details}"
    )


def canonicalize_bundle(model_path: Path, bundle_dir: Path, explicit_tokenizer: Optional[str]) -> None:
    encoder_source = find_first_file(
        bundle_dir,
        [
            CANONICAL_ENCODER,
            model_path.name,
            "encoder-model.onnx",
            "model.int8.onnx",
            "model.onnx",
        ],
    )
    if encoder_source is None and model_path.exists() and model_path.is_file():
        encoder_source = model_path
    if encoder_source is None:
        raise RunnerError(
            "MODEL_LOAD_ERROR: Missing encoder artifact after onnx-asr model preparation."
        )

    decoder_source = find_first_file(
        bundle_dir,
        [CANONICAL_DECODER, "decoder_joint-model.onnx"],
    )
    if decoder_source is None:
        raise RunnerError(
            "MODEL_LOAD_ERROR: Missing decoder artifact after onnx-asr model preparation."
        )

    config_source = find_first_file(bundle_dir, [CANONICAL_CONFIG])
    if config_source is None:
        raise RunnerError("MODEL_LOAD_ERROR: Missing config.json after onnx-asr model preparation.")

    normalizer_source = find_first_file(bundle_dir, [CANONICAL_NORMALIZER])
    if normalizer_source is None:
        raise RunnerError("MODEL_LOAD_ERROR: Missing nemo128.onnx after onnx-asr model preparation.")

    vocab_source = find_first_file(bundle_dir, [CANONICAL_VOCAB])

    if explicit_tokenizer:
        explicit = Path(explicit_tokenizer).expanduser().resolve()
        ensure_file_exists(explicit, "Tokenizer file")
        suffix = explicit.suffix.lower()
        if suffix == ".txt":
            vocab_source = explicit
        elif suffix == ".model":
            copy_if_needed(explicit, bundle_dir / "tokenizer.model")
        elif suffix == ".json":
            copy_if_needed(explicit, bundle_dir / "tokenizer.json")

    if vocab_source is None:
        raise RunnerError(
            "TOKENIZER_MISSING: Missing vocab.txt after onnx-asr model preparation."
        )

    canonical_encoder_path = bundle_dir / CANONICAL_ENCODER
    canonical_decoder_path = bundle_dir / CANONICAL_DECODER
    canonical_config_path = bundle_dir / CANONICAL_CONFIG
    canonical_normalizer_path = bundle_dir / CANONICAL_NORMALIZER
    canonical_vocab_path = bundle_dir / CANONICAL_VOCAB

    copy_if_needed(encoder_source, canonical_encoder_path)
    copy_if_needed(decoder_source, canonical_decoder_path)
    copy_if_needed(config_source, canonical_config_path)
    copy_if_needed(normalizer_source, canonical_normalizer_path)
    copy_if_needed(vocab_source, canonical_vocab_path)

    # Keep Swift-side validation path stable: model alias points at encoder int8 graph.
    copy_if_needed(canonical_encoder_path, model_path)


def prepare_bundle(model_path: Path, explicit_tokenizer: Optional[str]) -> Path:
    model_path.parent.mkdir(parents=True, exist_ok=True)
    bundle_dir = model_path.parent

    canonicalize_bundle(model_path=model_path, bundle_dir=bundle_dir, explicit_tokenizer=explicit_tokenizer)
    _ = load_parakeet_model(load_onnx_asr(), bundle_dir)
    return bundle_dir


class InferenceEngine:
    def __init__(self, model_path: Path, explicit_tokenizer: Optional[str]):
        self.model_path = model_path
        self.explicit_tokenizer = explicit_tokenizer
        self.bundle_dir = prepare_bundle(model_path=model_path, explicit_tokenizer=explicit_tokenizer)
        self.onnx_asr_model = load_parakeet_model(load_onnx_asr(), self.bundle_dir)

    def close(self) -> None:
        # Keep prepared artifacts on disk for reuse across sessions.
        return

    def transcribe(self, audio_path: Path) -> str:
        result = self.onnx_asr_model.recognize(str(audio_path), sample_rate=16000)
        text = str(result).strip()
        if text:
            return text
        raise RunnerError("INFERENCE_ERROR: onnx-asr returned empty transcript.")


def run_inference(model_path: Path, audio_path: Path, explicit_tokenizer: Optional[str]) -> str:
    engine = InferenceEngine(model_path, explicit_tokenizer)
    try:
        return engine.transcribe(audio_path)
    finally:
        engine.close()


def check_runtime(model_path: Path, explicit_tokenizer: Optional[str]) -> None:
    engine = InferenceEngine(model_path, explicit_tokenizer)
    engine.close()


def write_worker_response(request_id: str, ok: bool, payload: Dict[str, object]) -> None:
    response: Dict[str, object] = {"id": request_id, "ok": ok}
    response.update(payload)
    sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def serve_loop(model_path: Path, explicit_tokenizer: Optional[str]) -> int:
    engine = InferenceEngine(model_path, explicit_tokenizer)
    atexit.register(engine.close)

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue

        request_id = ""
        try:
            payload = json.loads(line)
            if not isinstance(payload, dict):
                raise RunnerError("REQUEST_ERROR: Worker request payload must be a JSON object.")

            request_id = str(payload.get("id", ""))
            op = str(payload.get("op", "transcribe")).strip().lower()

            if op == "shutdown":
                write_worker_response(request_id, True, {"message": "bye"})
                break
            if op == "ping":
                write_worker_response(request_id, True, {"message": "ready"})
                continue
            if op != "transcribe":
                raise RunnerError(f"REQUEST_ERROR: Unsupported worker op '{op}'.")

            audio_raw = payload.get("audio")
            if not isinstance(audio_raw, str) or not audio_raw.strip():
                raise RunnerError("REQUEST_ERROR: 'audio' path is required for transcribe requests.")

            audio_path = Path(audio_raw).expanduser().resolve()
            ensure_file_exists(audio_path, "Audio file")
            text = engine.transcribe(audio_path)
            write_worker_response(request_id, True, {"text": text})
        except RunnerError as exc:
            write_worker_response(request_id, False, {"error": str(exc)})
        except Exception as exc:  # pragma: no cover - unexpected worker error
            write_worker_response(request_id, False, {"error": f"INFERENCE_ERROR: {exc}"})

    engine.close()
    return 0


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    model_path = Path(args.model).expanduser().resolve()

    if args.check:
        check_runtime(model_path, args.tokenizer)
        print("ok")
        return 0

    if args.serve:
        return serve_loop(model_path, args.tokenizer)

    audio_path = Path(args.audio).expanduser().resolve()
    ensure_file_exists(audio_path, "Audio file")

    text = run_inference(model_path, audio_path, args.tokenizer)
    print(text)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except RunnerError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(2)
