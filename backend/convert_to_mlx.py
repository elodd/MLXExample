#!/usr/bin/env python3
"""Convert original Hugging Face model weights to an MLX model directory.

This script does not convert GGUF files. Pass a Hugging Face repository ID or
a local directory containing the original Hugging Face-format model weights.
"""

from __future__ import annotations

import argparse
import platform
import sys
from pathlib import Path


DEFAULT_MODEL = "Qwen/Qwen3-4B"
DEFAULT_OUTPUT = Path("Qwen/Qwen3-4B-4bit-mlx")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert Hugging Face model weights to MLX format.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help="Hugging Face repository ID or local Hugging Face model directory.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help="New directory in which to write the converted MLX model.",
    )
    parser.add_argument(
        "--revision",
        default="main",
        help="Hugging Face branch, tag, or commit to download.",
    )
    parser.add_argument(
        "--bits",
        type=int,
        choices=(2, 3, 4, 6, 8),
        default=4,
        help="Number of bits per quantized weight.",
    )
    parser.add_argument(
        "--group-size",
        type=int,
        choices=(32, 64, 128),
        default=64,
        help="Quantization group size.",
    )
    parser.add_argument(
        "--no-quantize",
        action="store_true",
        help="Convert without quantizing the weights.",
    )
    parser.add_argument(
        "--trust-remote-code",
        action="store_true",
        help="Allow custom Hugging Face tokenizer code. Enable only for trusted models.",
    )
    parser.add_argument(
        "--upload-repo",
        help="Optionally upload the converted model to this Hugging Face repository.",
    )
    return parser.parse_args()


def validate(args: argparse.Namespace) -> None:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit(
            "MLX conversion requires an Apple-silicon Mac (Darwin arm64)."
        )

    if args.model.lower().endswith(".gguf"):
        raise SystemExit(
            "GGUF cannot be converted directly to MLX. Pass the original "
            "Hugging Face repository ID or model directory instead."
        )

    local_source = Path(args.model).expanduser()
    if ("/" not in args.model and not local_source.exists()) or (
        local_source.suffix.lower() == ".gguf"
    ):
        raise SystemExit(f"Model source does not exist: {local_source}")

    if args.output.exists():
        raise SystemExit(
            f"Output already exists: {args.output}\n"
            "Choose a different --output path or move the existing directory."
        )


def main() -> int:
    args = parse_args()
    validate(args)

    try:
        from mlx_lm import convert
        from huggingface_hub import snapshot_download
    except ImportError as error:
        raise SystemExit(
            "mlx-lm is not installed. Run:\n"
            "  python -m pip install -r requirements-mlx-convert.txt"
        ) from error

    args.output.parent.mkdir(parents=True, exist_ok=True)

    source = args.model
    local_source = Path(args.model).expanduser()
    if not local_source.exists():
        print(f"Completing Hugging Face snapshot: {args.model}@{args.revision}")
        # mlx-lm may initially download only model-related files, but its save
        # step later asks huggingface_hub for the complete cached snapshot.
        # Downloading the complete snapshot here prevents IncompleteSnapshotError.
        source = snapshot_download(repo_id=args.model, revision=args.revision)
        print(f"Cached source: {source}")

    print(f"Source: {args.model}")
    print(f"Output: {args.output}")
    print(
        "Quantization: disabled"
        if args.no_quantize
        else f"Quantization: {args.bits}-bit, group size {args.group_size}"
    )

    convert(
        source,
        mlx_path=str(args.output),
        quantize=not args.no_quantize,
        q_bits=args.bits,
        q_group_size=args.group_size,
        upload_repo=args.upload_repo,
        trust_remote_code=args.trust_remote_code,
    )

    print(f"Conversion complete: {args.output.resolve()}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nConversion cancelled.", file=sys.stderr)
        raise SystemExit(130)
