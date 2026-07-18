#!/usr/bin/env python3
"""MLX speech-to-text runner for Whisper Smart.

Runs entirely offline once models are cached. Avoids ffmpeg by decoding
WAV input with the standard library and feeding raw sample arrays to the
MLX packages.

Modes:
  --check                                  verify imports work (exit 0/1)
  --download --engine E --model REPO       prefetch model into the HF cache
  --engine E --model REPO --audio F.wav    transcribe; plain text on stdout

Engines: parakeet (parakeet-mlx), whisper (mlx-whisper).
Diagnostics go to stderr; stdout carries only the transcript.
"""

import argparse
import sys
import wave


def fail(message: str, code: int = 1) -> "NoReturn":  # noqa: F821
    print(message, file=sys.stderr)
    sys.exit(code)


def read_wav_float32(path: str):
    """Decode a WAV file to (float32 numpy array in [-1, 1], sample_rate)."""
    import numpy as np

    with wave.open(path, "rb") as wav:
        channels = wav.getnchannels()
        width = wav.getsampwidth()
        rate = wav.getframerate()
        frames = wav.readframes(wav.getnframes())

    if width == 2:
        samples = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
    elif width == 4:
        samples = np.frombuffer(frames, dtype=np.int32).astype(np.float32) / 2147483648.0
    else:
        fail(f"Unsupported WAV sample width: {width * 8}-bit")

    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)

    if rate != 16000:
        # Linear resample; capture side already records at 16 kHz, this is a
        # safety net rather than a hot path.
        duration = samples.shape[0] / rate
        target_count = int(duration * 16000)
        samples = np.interp(
            np.linspace(0.0, samples.shape[0] - 1, target_count),
            np.arange(samples.shape[0]),
            samples,
        ).astype(np.float32)

    return samples


def run_check() -> None:
    try:
        import parakeet_mlx  # noqa: F401
        import mlx_whisper  # noqa: F401
    except Exception as exc:  # pragma: no cover
        fail(f"MLX runtime import failed: {exc}")
    print("ok")


def run_download(engine: str, model: str) -> None:
    from huggingface_hub import snapshot_download

    if engine == "parakeet":
        # parakeet-mlx loads exactly these two files.
        snapshot_download(repo_id=model, allow_patterns=["config.json", "model.safetensors"])
    else:
        snapshot_download(repo_id=model)
    print("downloaded")


def transcribe_parakeet(model_repo: str, audio_path: str) -> str:
    import mlx.core as mx
    from parakeet_mlx import from_pretrained
    from parakeet_mlx.audio import get_logmel

    samples = read_wav_float32(audio_path)
    model = from_pretrained(model_repo)
    mel = get_logmel(mx.array(samples), model.preprocessor_config)
    results = model.generate(mel)
    if not results:
        return ""
    return results[0].text.strip()


def transcribe_whisper(model_repo: str, audio_path: str) -> str:
    import mlx_whisper

    samples = read_wav_float32(audio_path)
    result = mlx_whisper.transcribe(samples, path_or_hf_repo=model_repo)
    return str(result.get("text", "")).strip()


def main() -> None:
    parser = argparse.ArgumentParser(description="MLX STT runner")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--engine", choices=["parakeet", "whisper"])
    parser.add_argument("--model")
    parser.add_argument("--audio")
    args = parser.parse_args()

    if args.check:
        run_check()
        return

    if not args.engine or not args.model:
        fail("--engine and --model are required")

    if args.download:
        run_download(args.engine, args.model)
        return

    if not args.audio:
        fail("--audio is required for transcription")

    if args.engine == "parakeet":
        text = transcribe_parakeet(args.model, args.audio)
    else:
        text = transcribe_whisper(args.model, args.audio)

    print(text)


if __name__ == "__main__":
    main()
