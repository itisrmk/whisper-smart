#!/usr/bin/env python3
"""Local Parakeet ONNX inference runner for VisperflowClone.

Usage:
  python3 scripts/parakeet_infer.py --model /path/model.onnx --audio /path/audio.wav
  python3 scripts/parakeet_infer.py --check --model /path/model.onnx
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import wave
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence


class RunnerError(RuntimeError):
    """Error that should be surfaced directly to the caller."""


def raise_dependency_error(module_name: str, exc: Exception) -> None:
    raise RunnerError(
        "DEPENDENCY_MISSING: Python package "
        f"'{module_name}' is required ({exc}). "
        "Use Visperflow Settings → Provider → Repair Parakeet Runtime."
    )


def load_core_dependencies():
    try:
        import numpy as np  # type: ignore
    except ModuleNotFoundError as exc:
        raise_dependency_error("numpy", exc)
    except Exception as exc:  # pragma: no cover - unexpected import failure
        raise RunnerError(f"DEPENDENCY_ERROR: Failed to import numpy: {exc}") from exc

    try:
        import onnxruntime as ort  # type: ignore
    except ModuleNotFoundError as exc:
        raise_dependency_error("onnxruntime", exc)
    except Exception as exc:  # pragma: no cover - unexpected import failure
        raise RunnerError(f"DEPENDENCY_ERROR: Failed to import onnxruntime: {exc}") from exc

    return np, ort


def load_sentencepiece():
    try:
        import sentencepiece as spm  # type: ignore
    except ModuleNotFoundError as exc:
        raise_dependency_error("sentencepiece", exc)
    except Exception as exc:  # pragma: no cover - unexpected import failure
        raise RunnerError(f"DEPENDENCY_ERROR: Failed to import sentencepiece: {exc}") from exc
    return spm


def load_onnx_asr():
    try:
        import onnx_asr  # type: ignore
    except ModuleNotFoundError as exc:
        raise_dependency_error("onnx-asr", exc)
    except Exception as exc:  # pragma: no cover - unexpected import failure
        raise RunnerError(f"DEPENDENCY_ERROR: Failed to import onnx-asr: {exc}") from exc
    return onnx_asr


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run local NVIDIA Parakeet ONNX inference.")
    parser.add_argument("--model", required=True, help="Path to Parakeet ONNX model file.")
    parser.add_argument("--audio", help="Path to mono 16 kHz WAV audio.")
    parser.add_argument(
        "--tokenizer",
        help="Optional tokenizer path (tokenizer.model, tokenizer.json, or vocab.txt).",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Validate runtime/dependencies/model without running inference.",
    )
    args = parser.parse_args(argv)
    if not args.check and not args.audio:
        parser.error("--audio is required unless --check is used")
    return args


def ensure_file_exists(path: Path, label: str) -> None:
    if not path.exists():
        raise RunnerError(f"{label} not found: {path}")
    if not path.is_file():
        raise RunnerError(f"{label} is not a file: {path}")


def load_session(model_path: Path, ort):
    so = ort.SessionOptions()
    so.log_severity_level = 3
    try:
        return ort.InferenceSession(str(model_path), sess_options=so, providers=["CPUExecutionProvider"])
    except Exception as exc:
        raise RunnerError(
            "MODEL_LOAD_ERROR: Failed to load ONNX model. "
            "Ensure the file is a valid Parakeet ONNX export. "
            f"Details: {exc}"
        ) from exc


def read_wav_mono_16k(audio_path: Path, np):
    try:
        with wave.open(str(audio_path), "rb") as wf:
            channels = wf.getnchannels()
            sample_width = wf.getsampwidth()
            sample_rate = wf.getframerate()
            frame_count = wf.getnframes()
            frame_bytes = wf.readframes(frame_count)
    except wave.Error as exc:
        raise RunnerError(
            "AUDIO_FORMAT_ERROR: Failed to parse WAV input. "
            "Provide a valid PCM WAV file. "
            f"Details: {exc}"
        ) from exc

    if channels != 1:
        raise RunnerError(f"AUDIO_FORMAT_ERROR: Expected mono WAV but received {channels} channels.")
    if sample_width != 2:
        raise RunnerError(
            f"AUDIO_FORMAT_ERROR: Expected 16-bit PCM WAV but sample width is {sample_width} bytes."
        )
    if sample_rate != 16_000:
        raise RunnerError(
            f"AUDIO_FORMAT_ERROR: Expected 16 kHz WAV but received {sample_rate} Hz."
        )

    samples = np.frombuffer(frame_bytes, dtype=np.int16).astype(np.float32) / 32768.0
    if samples.size == 0:
        raise RunnerError("AUDIO_FORMAT_ERROR: WAV file contains no audio frames.")
    return samples


def pick_audio_input(session_inputs):
    float_inputs = [inp for inp in session_inputs if "tensor(float)" in inp.type]
    if not float_inputs:
        raise RunnerError(
            "MODEL_SIGNATURE_ERROR: ONNX model has no float tensor input for audio."
        )

    preferred = ("audio", "signal", "wave", "input")
    for inp in float_inputs:
        lowered = inp.name.lower()
        if any(token in lowered for token in preferred):
            return inp
    return float_inputs[0]


def pick_length_input(session_inputs):
    int_inputs = [
        inp
        for inp in session_inputs
        if "tensor(int64)" in inp.type or "tensor(int32)" in inp.type
    ]
    preferred = ("length", "len", "duration")
    for inp in int_inputs:
        lowered = inp.name.lower()
        if any(token in lowered for token in preferred):
            return inp
    if len(int_inputs) == 1:
        return int_inputs[0]
    return None


def make_audio_tensor(audio, input_arg, np):
    rank = len(input_arg.shape) if input_arg.shape is not None else None
    if rank == 1:
        return audio.astype(np.float32)
    if rank is None or rank == 2:
        return audio.astype(np.float32)[None, :]
    raise RunnerError(
        "MODEL_SIGNATURE_ERROR: Unsupported audio input rank "
        f"{rank} for '{input_arg.name}'. "
        "Expected rank 1 or 2 raw-audio input."
    )


def make_length_tensor(sample_count: int, input_arg, np):
    dtype = np.int64 if "int64" in input_arg.type else np.int32
    return np.array([sample_count], dtype=dtype)


def model_metadata(session) -> Dict[str, str]:
    meta = session.get_modelmeta()
    raw = meta.custom_metadata_map or {}
    return dict(raw)


def parse_blank_id(meta: Dict[str, str]) -> int:
    for key in ("blank_id", "ctc_blank_id", "ctcBlankId"):
        if key in meta:
            try:
                return int(meta[key])
            except ValueError:
                pass
    return 0


def parse_token_list(value: str) -> Optional[List[str]]:
    if not value:
        return None

    try:
        parsed = json.loads(value)
        if isinstance(parsed, list):
            return [str(x) for x in parsed]
        if isinstance(parsed, dict):
            pairs = []
            for key, val in parsed.items():
                try:
                    idx = int(key)
                except ValueError:
                    continue
                pairs.append((idx, str(val)))
            if pairs:
                pairs.sort(key=lambda x: x[0])
                return [token for _, token in pairs]
    except json.JSONDecodeError:
        pass

    if "\n" in value:
        lines = [line.strip() for line in value.splitlines() if line.strip()]
        if lines:
            return lines

    if "|" in value:
        parts = [part for part in value.split("|")]
        if len(parts) > 10:
            return parts
    return None


def labels_from_metadata(meta: Dict[str, str]) -> Optional[List[str]]:
    for key in ("labels", "vocabulary", "vocab", "tokens", "id2label"):
        if key in meta:
            parsed = parse_token_list(meta[key])
            if parsed:
                return parsed
    return None


def ctc_collapse(token_ids: Iterable[int], blank_id: int) -> List[int]:
    collapsed: List[int] = []
    previous = None
    for token in token_ids:
        if token == blank_id:
            previous = token
            continue
        if token != previous:
            collapsed.append(int(token))
        previous = token
    return collapsed


def infer_token_ids(outputs, meta: Dict[str, str], np) -> List[int]:
    blank_id = parse_blank_id(meta)

    for output in outputs:
        if not hasattr(output, "dtype") or not hasattr(output, "ndim"):
            continue

        if np.issubdtype(output.dtype, np.integer):
            flattened = output.reshape(-1).astype(np.int64).tolist()
            return ctc_collapse(flattened, blank_id)

        if np.issubdtype(output.dtype, np.floating):
            logits = output
            if logits.ndim == 3:
                logits = logits[0]
            if logits.ndim != 2:
                continue
            token_ids = np.argmax(logits, axis=-1).astype(np.int64).tolist()
            return ctc_collapse(token_ids, blank_id)

    raise RunnerError(
        "MODEL_OUTPUT_ERROR: Could not find a supported logits/token-id output tensor."
    )


def find_tokenizer_path(model_path: Path, explicit: Optional[str]) -> Optional[Path]:
    if explicit:
        path = Path(explicit).expanduser().resolve()
        ensure_file_exists(path, "Tokenizer file")
        return path

    model_dir = model_path.parent
    for filename in ("tokenizer.model", "tokenizer.json", "vocab.txt"):
        candidate = model_dir / filename
        if candidate.exists() and candidate.is_file():
            return candidate
    return None


def decode_with_vocab(token_ids: List[int], vocab: List[str]) -> str:
    pieces: List[str] = []
    for token_id in token_ids:
        if 0 <= token_id < len(vocab):
            pieces.append(vocab[token_id])
    text = "".join(pieces)
    return normalize_text(text)


def decode_with_tokenizer_json(token_ids: List[int], tokenizer_path: Path) -> str:
    try:
        with tokenizer_path.open("r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as exc:
        raise RunnerError(f"TOKENIZER_ERROR: Failed to parse tokenizer.json: {exc}") from exc

    model_obj = data.get("model", {})
    vocab_map = model_obj.get("vocab")
    if not isinstance(vocab_map, dict):
        raise RunnerError("TOKENIZER_ERROR: tokenizer.json missing model.vocab object.")

    if not vocab_map:
        raise RunnerError("TOKENIZER_ERROR: tokenizer.json model.vocab is empty.")

    max_id = max(int(v) for v in vocab_map.values())
    vocab = [""] * (max_id + 1)
    for token, idx in vocab_map.items():
        vocab[int(idx)] = token
    return decode_with_vocab(token_ids, vocab)


def decode_with_vocab_file(token_ids: List[int], vocab_path: Path) -> str:
    try:
        with vocab_path.open("r", encoding="utf-8") as f:
            vocab = [line.rstrip("\n\r") for line in f]
    except Exception as exc:
        raise RunnerError(f"TOKENIZER_ERROR: Failed to read vocab.txt: {exc}") from exc
    return decode_with_vocab(token_ids, vocab)


def decode_with_sentencepiece(token_ids: List[int], tokenizer_path: Path) -> str:
    spm = load_sentencepiece()
    try:
        processor = spm.SentencePieceProcessor(model_file=str(tokenizer_path))
    except Exception as exc:
        raise RunnerError(f"TOKENIZER_ERROR: Failed to load tokenizer.model: {exc}") from exc
    try:
        text = processor.decode(token_ids)
    except Exception as exc:
        raise RunnerError(f"TOKENIZER_ERROR: SentencePiece decode failed: {exc}") from exc
    return normalize_text(text)


def normalize_text(text: str) -> str:
    normalized = text
    normalized = normalized.replace("▁", " ")
    for token in ("<unk>", "<s>", "</s>", "<pad>", "<blank>", "<blk>"):
        normalized = normalized.replace(token, "")
    normalized = " ".join(normalized.split())
    return normalized.strip()


def decode_tokens(
    token_ids: List[int],
    meta: Dict[str, str],
    model_path: Path,
    explicit_tokenizer: Optional[str],
) -> str:
    labels = labels_from_metadata(meta)
    if labels:
        return decode_with_vocab(token_ids, labels)

    tokenizer_path = find_tokenizer_path(model_path, explicit_tokenizer)
    if tokenizer_path is None:
        raise RunnerError(
            "TOKENIZER_MISSING: Could not decode token IDs because no vocabulary metadata or tokenizer file was found. "
            "Provide tokenizer.model, tokenizer.json, or vocab.txt next to the ONNX model, "
            "or re-download model artifacts from Visperflow Settings -> Provider."
        )

    suffix = tokenizer_path.name.lower()
    if suffix.endswith(".model"):
        return decode_with_sentencepiece(token_ids, tokenizer_path)
    if suffix.endswith(".json"):
        return decode_with_tokenizer_json(token_ids, tokenizer_path)
    if suffix.endswith(".txt"):
        return decode_with_vocab_file(token_ids, tokenizer_path)

    raise RunnerError(
        f"TOKENIZER_ERROR: Unsupported tokenizer file extension: {tokenizer_path.suffix}"
    )


def validate_setup(session, model_path: Path, explicit_tokenizer: Optional[str]) -> None:
    session_inputs = session.get_inputs()
    audio_input = pick_audio_input(session_inputs)
    rank = len(audio_input.shape) if audio_input.shape is not None else 2
    if rank not in (1, 2):
        raise RunnerError(
            "MODEL_SIGNATURE_ERROR: Unsupported ONNX audio input signature. "
            f"Input '{audio_input.name}' has rank {rank}; expected rank 1 or 2 raw audio."
        )

    meta = model_metadata(session)
    labels = labels_from_metadata(meta)
    if labels:
        return

    tokenizer = find_tokenizer_path(model_path, explicit_tokenizer)
    if tokenizer is None:
        raise RunnerError(
            "TOKENIZER_MISSING: No labels in model metadata and no tokenizer file found."
        )

    if tokenizer.suffix.lower() == ".model":
        _ = load_sentencepiece()


def run_inference(
    model_path: Path,
    audio_path: Path,
    explicit_tokenizer: Optional[str],
) -> str:
    # Preferred path: onnx-asr handles Parakeet preprocessing/signature variants.
    try:
        onnx_asr = load_onnx_asr()
        model = None
        last_error: Exception | None = None
        for quant in (None, "int8"):
            try:
                model = onnx_asr.load_model(
                    "nemo-parakeet-ctc-0.6b",
                    path=str(model_path.parent),
                    quantization=quant,
                    providers=["CPUExecutionProvider"],
                )
                break
            except Exception as exc:
                last_error = exc

        if model is None and last_error is not None:
            raise last_error
        if model is None:
            raise RunnerError("INFERENCE_ERROR: Failed to initialize onnx-asr model.")

        result = model.recognize(str(audio_path), sample_rate=16000)
        text = str(result).strip()
        if text:
            return text
        raise RunnerError("INFERENCE_ERROR: onnx-asr returned empty transcript.")
    except RunnerError:
        raise
    except Exception:
        # Fallback path for raw-audio compatible exports.
        pass

    np, ort = load_core_dependencies()
    session = load_session(model_path, ort)

    audio = read_wav_mono_16k(audio_path, np)

    session_inputs = session.get_inputs()
    audio_input = pick_audio_input(session_inputs)
    length_input = pick_length_input(session_inputs)

    feeds = {audio_input.name: make_audio_tensor(audio, audio_input, np)}
    if length_input is not None:
        feeds[length_input.name] = make_length_tensor(audio.shape[0], length_input, np)

    try:
        outputs = session.run(None, feeds)
    except Exception as exc:
        raise RunnerError(
            "INFERENCE_ERROR: ONNX runtime execution failed. "
            "Ensure the model is a Parakeet CTC ONNX export expecting raw audio input. "
            f"Details: {exc}"
        ) from exc

    if not outputs:
        raise RunnerError("MODEL_OUTPUT_ERROR: ONNX session produced no output tensors.")

    meta = model_metadata(session)
    token_ids = infer_token_ids(outputs, meta, np)
    text = decode_tokens(token_ids, meta, model_path, explicit_tokenizer)
    return text


def check_runtime(model_path: Path, explicit_tokenizer: Optional[str]) -> None:
    # Preferred check path via onnx-asr (supports Parakeet preprocessing graph requirements).
    try:
        onnx_asr = load_onnx_asr()
        last_error: Exception | None = None
        for quant in (None, "int8"):
            try:
                _ = onnx_asr.load_model(
                    "nemo-parakeet-ctc-0.6b",
                    path=str(model_path.parent),
                    quantization=quant,
                    providers=["CPUExecutionProvider"],
                )
                return
            except Exception as exc:
                last_error = exc
        if last_error is not None:
            raise last_error
    except RunnerError:
        raise
    except Exception:
        # Fallback to legacy raw-audio validator.
        pass

    _, ort = load_core_dependencies()
    session = load_session(model_path, ort)
    validate_setup(session, model_path, explicit_tokenizer)


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    model_path = Path(args.model).expanduser().resolve()
    ensure_file_exists(model_path, "Model file")

    if args.check:
        check_runtime(model_path, args.tokenizer)
        print("ok")
        return 0

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
