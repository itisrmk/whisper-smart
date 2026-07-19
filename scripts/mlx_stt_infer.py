#!/usr/bin/env python3
"""MLX speech-to-text runner for Whisper Smart.

Runs entirely offline once models are cached. Avoids ffmpeg by decoding
WAV input with the standard library and feeding raw sample arrays to the
MLX packages.

Modes:
  --check                                  verify imports work (exit 0/1)
  --download --engine E --model REPO       prefetch model into the HF cache
  --engine E --model REPO --audio F.wav    transcribe; plain text on stdout
  --serve --engine E --model REPO          long-lived daemon: load the model
                                           once, then serve JSONL requests

Serve protocol (newline-delimited JSON):
  stdout after model load + warmup:  {"event": "ready"}

  Batch request (whole utterance at once):
  stdin:   {"id": 1, "audio": "/path/to.wav"}
           {"id": 1, "pcm": "<base64 int16 LE mono 16kHz>"}
  stdout:  {"id": 1, "text": "..."} | {"id": 1, "error": "..."}

  Streaming session (audio fed while the user is still speaking, so most
  of the inference is done by the time the utterance ends):
  stdin:   {"cmd": "start", "id": 2}
  stdout:  {"id": 2, "event": "stream_started"} | {"id": 2, "error": "..."}
  stdin:   {"cmd": "audio", "pcm": "<base64 int16>"}     (no response)
  stdin:   {"cmd": "end", "id": 3}
  stdout:  {"id": 3, "text": "..."} | {"id": 3, "error": "..."}
  stdin:   {"cmd": "cancel"}                             (no response)

  parakeet streams incrementally (transcribe_stream); whisper has no
  streaming decode, so a "stream" accumulates samples and transcribes on
  "end" — still skipping the WAV/disk round-trip.
  EOF on stdin terminates the daemon.

Engines: parakeet (parakeet-mlx), whisper (mlx-whisper).
Diagnostics go to stderr; stdout carries only the transcript / protocol JSON.
"""

import argparse
import json
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


def decode_pcm_base64(b64: str):
    """Decode base64 int16 LE mono 16 kHz PCM to float32 in [-1, 1]."""
    import base64

    import numpy as np

    raw = base64.b64decode(b64)
    return np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0


class ParakeetStream:
    """One transcription session fed incrementally over the wire.

    Once the clip passes BATCH_STREAM_CROSSOVER_SAMPLES, the incremental
    (local-attention) transcriber opens and audio is decoded in
    FLUSH_SAMPLES chunks *while the user is still speaking*, so finish()
    only has to decode the sub-chunk tail — release-to-text latency stays
    near-constant instead of growing with clip duration. The final
    `result` already merges finalized + draft tokens, so no separate
    refine pass exists or is needed (parakeet-mlx StreamingParakeet).

    Clips that never reach the crossover are batch-transcribed on
    finish() instead: batch decode of ~2 s of audio is effectively
    instant and uses full attention, so it is both faster and higher
    quality than opening a streaming context for a tiny clip.
    """

    FLUSH_SAMPLES = 16_000  # 1 s at 16 kHz
    BATCH_STREAM_CROSSOVER_SAMPLES = 2 * 16_000

    def __init__(self, model, batch_transcribe):
        self._model = model
        self._batch = batch_transcribe
        self._ctx = None
        self._transcriber = None
        self._chunks = []
        self._total = 0
        self._streamed = 0
        self._closed = False

    def add(self, samples) -> None:
        self._chunks.append(samples)
        self._total += samples.shape[0]
        if self._total > self.BATCH_STREAM_CROSSOVER_SAMPLES:
            self._ensure_transcriber()
            self._feed_backlog(min_backlog=self.FLUSH_SAMPLES)

    def _all_samples(self):
        import numpy as np

        if len(self._chunks) > 1:
            self._chunks = [np.concatenate(self._chunks)]
        return self._chunks[0]

    def _ensure_transcriber(self) -> None:
        if self._transcriber is None:
            self._ctx = self._model.transcribe_stream(context_size=(256, 256), depth=1)
            self._transcriber = self._ctx.__enter__()

    def _feed_backlog(self, min_backlog: int) -> None:
        import mlx.core as mx

        if self._total - self._streamed < min_backlog:
            return
        samples = self._all_samples()
        self._transcriber.add_audio(mx.array(samples[self._streamed:]))
        self._streamed = self._total

    def finish(self) -> str:
        if self._total == 0:
            self.close()
            return ""

        if self._transcriber is None:
            samples = self._all_samples()
            self.close()
            return self._batch(samples)

        self._feed_backlog(min_backlog=1)
        # result combines finalized + draft tokens; read before __exit__
        # frees the streaming buffers.
        text = self._transcriber.result.text.strip()
        self.close()
        return text

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        if self._ctx is not None:
            try:
                self._ctx.__exit__(None, None, None)
            except Exception as exc:  # pragma: no cover - cleanup is best-effort
                print(f"parakeet stream close failed: {exc}", file=sys.stderr)


class AccumulatingStream:
    """Stream facade for engines without incremental decode (whisper):
    buffers samples and runs one batch transcription on finish()."""

    def __init__(self, batch_transcribe):
        self._batch = batch_transcribe
        self._chunks = []

    def add(self, samples) -> None:
        self._chunks.append(samples)

    def finish(self) -> str:
        import numpy as np

        if not self._chunks:
            return ""
        samples = self._chunks[0] if len(self._chunks) == 1 else np.concatenate(self._chunks)
        self._chunks = []
        return self._batch(samples)

    def close(self) -> None:
        self._chunks = []


class Engine:
    """Loaded model exposing batch transcription and streaming sessions."""

    def __init__(self, batch, open_stream):
        self.batch = batch
        self.open_stream = open_stream


def load_engine(engine: str, model_repo: str) -> Engine:
    """Load the model once; returns batch + streaming entry points."""
    if engine == "parakeet":
        import mlx.core as mx
        from parakeet_mlx import from_pretrained
        from parakeet_mlx.audio import get_logmel

        model = from_pretrained(model_repo)

        def batch(samples) -> str:
            mel = get_logmel(mx.array(samples), model.preprocessor_config)
            results = model.generate(mel)
            if not results:
                return ""
            return results[0].text.strip()

        return Engine(batch=batch, open_stream=lambda: ParakeetStream(model, batch))

    import mlx_whisper

    def batch(samples) -> str:
        # mlx_whisper caches the loaded model per repo internally, so only
        # the first call pays the weight-loading cost. A single temperature
        # disables the multi-pass fallback schedule, and conditioning on
        # previous text is useless for one-shot dictation — both cut decode
        # time substantially on short utterances.
        result = mlx_whisper.transcribe(
            samples,
            path_or_hf_repo=model_repo,
            verbose=None,
            temperature=0.0,
            condition_on_previous_text=False,
        )
        return str(result.get("text", "")).strip()

    return Engine(batch=batch, open_stream=lambda: AccumulatingStream(batch))


def load_transcriber(engine: str, model_repo: str):
    """Back-compat: samples -> text callable (batch only)."""
    return load_engine(engine, model_repo).batch


def transcribe_parakeet(model_repo: str, audio_path: str) -> str:
    return load_transcriber("parakeet", model_repo)(read_wav_float32(audio_path))


def transcribe_whisper(model_repo: str, audio_path: str) -> str:
    return load_transcriber("whisper", model_repo)(read_wav_float32(audio_path))


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def run_serve(engine: str, model_repo: str) -> None:
    import numpy as np

    loaded = load_engine(engine, model_repo)

    # Warm up: triggers weight loading (whisper) and Metal kernel compilation
    # so the first real request runs at steady-state speed.
    try:
        loaded.batch(np.zeros(8000, dtype=np.float32))
    except Exception as exc:  # pragma: no cover - warmup is best-effort
        print(f"warmup failed: {exc}", file=sys.stderr)

    emit({"event": "ready"})

    stream = None
    stream_error = None

    def close_stream() -> None:
        nonlocal stream, stream_error
        if stream is not None:
            stream.close()
        stream = None
        stream_error = None

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError as exc:
            emit({"error": f"malformed request: {exc}"})
            continue

        request_id = request.get("id")
        cmd = request.get("cmd")

        if cmd == "start":
            close_stream()
            try:
                stream = loaded.open_stream()
                emit({"id": request_id, "event": "stream_started"})
            except Exception as exc:
                stream = None
                emit({"id": request_id, "error": f"stream start failed: {exc}"})
            continue

        if cmd == "audio":
            if stream is None or stream_error is not None:
                continue
            try:
                stream.add(decode_pcm_base64(request.get("pcm") or ""))
            except Exception as exc:
                # Remember the failure; it surfaces on "end" so the client
                # can fall back to a batch request.
                stream_error = str(exc)
            continue

        if cmd == "end":
            if stream is None:
                emit({"id": request_id, "error": "no streaming session active"})
                continue
            if stream_error is not None:
                error = stream_error
                close_stream()
                emit({"id": request_id, "error": f"stream audio failed: {error}"})
                continue
            try:
                text = stream.finish()
                emit({"id": request_id, "text": text})
            except Exception as exc:
                emit({"id": request_id, "error": str(exc)})
            finally:
                close_stream()
            continue

        if cmd == "cancel":
            close_stream()
            continue

        # Batch request: inline PCM preferred, WAV path kept for back-compat.
        pcm_b64 = request.get("pcm")
        audio_path = request.get("audio")
        try:
            if pcm_b64:
                samples = decode_pcm_base64(pcm_b64)
            elif audio_path:
                samples = read_wav_float32(audio_path)
            else:
                emit({"id": request_id, "error": "missing 'pcm' or 'audio'"})
                continue
            emit({"id": request_id, "text": loaded.batch(samples)})
        except Exception as exc:
            emit({"id": request_id, "error": str(exc)})


def main() -> None:
    parser = argparse.ArgumentParser(description="MLX STT runner")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--serve", action="store_true")
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

    if args.serve:
        run_serve(args.engine, args.model)
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
