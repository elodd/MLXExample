from __future__ import annotations

import argparse
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType
from unittest.mock import Mock, patch

from backend.src import convert_to_mlx


class ParseArgsTests(unittest.TestCase):
    def test_defaults(self) -> None:
        with patch.object(sys, "argv", ["convert_to_mlx.py"]):
            args = convert_to_mlx.parse_args()

        self.assertEqual(args.model, convert_to_mlx.DEFAULT_MODEL)
        self.assertEqual(args.output, convert_to_mlx.DEFAULT_OUTPUT)
        self.assertEqual(args.revision, "main")
        self.assertEqual(args.bits, 4)
        self.assertEqual(args.group_size, 64)
        self.assertFalse(args.no_quantize)
        self.assertFalse(args.trust_remote_code)
        self.assertIsNone(args.upload_repo)

    def test_custom_options(self) -> None:
        argv = [
            "convert_to_mlx.py",
            "--model",
            "org/model",
            "--output",
            "converted",
            "--revision",
            "v1",
            "--bits",
            "8",
            "--group-size",
            "128",
            "--no-quantize",
            "--trust-remote-code",
            "--upload-repo",
            "org/converted",
        ]

        with patch.object(sys, "argv", argv):
            args = convert_to_mlx.parse_args()

        self.assertEqual(args.model, "org/model")
        self.assertEqual(args.output, Path("converted"))
        self.assertEqual(args.revision, "v1")
        self.assertEqual(args.bits, 8)
        self.assertEqual(args.group_size, 128)
        self.assertTrue(args.no_quantize)
        self.assertTrue(args.trust_remote_code)
        self.assertEqual(args.upload_repo, "org/converted")


class ValidateTests(unittest.TestCase):
    @staticmethod
    def args(model: str, output: Path) -> argparse.Namespace:
        return argparse.Namespace(model=model, output=output)

    def test_rejects_non_apple_silicon(self) -> None:
        args = self.args("org/model", Path("output"))

        with (
            patch.object(convert_to_mlx.platform, "system", return_value="Linux"),
            patch.object(convert_to_mlx.platform, "machine", return_value="x86_64"),
            self.assertRaisesRegex(SystemExit, "Apple-silicon Mac"),
        ):
            convert_to_mlx.validate(args)

    def test_rejects_gguf_source(self) -> None:
        args = self.args("model.GGUF", Path("output"))

        with (
            patch.object(convert_to_mlx.platform, "system", return_value="Darwin"),
            patch.object(convert_to_mlx.platform, "machine", return_value="arm64"),
            self.assertRaisesRegex(SystemExit, "GGUF cannot be converted"),
        ):
            convert_to_mlx.validate(args)

    def test_rejects_missing_local_source(self) -> None:
        args = self.args("missing-model", Path("output"))

        with (
            patch.object(convert_to_mlx.platform, "system", return_value="Darwin"),
            patch.object(convert_to_mlx.platform, "machine", return_value="arm64"),
            self.assertRaisesRegex(SystemExit, "Model source does not exist"),
        ):
            convert_to_mlx.validate(args)

    def test_rejects_existing_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source"
            output = root / "output"
            source.mkdir()
            output.mkdir()
            args = self.args(str(source), output)

            with (
                patch.object(convert_to_mlx.platform, "system", return_value="Darwin"),
                patch.object(convert_to_mlx.platform, "machine", return_value="arm64"),
                self.assertRaisesRegex(SystemExit, "Output already exists"),
            ):
                convert_to_mlx.validate(args)

    def test_accepts_hugging_face_repository(self) -> None:
        args = self.args("org/model", Path("output"))

        with (
            patch.object(convert_to_mlx.platform, "system", return_value="Darwin"),
            patch.object(convert_to_mlx.platform, "machine", return_value="arm64"),
        ):
            convert_to_mlx.validate(args)


class MainTests(unittest.TestCase):
    def run_main(
        self, args: argparse.Namespace, snapshot_result: str = "/cached/model"
    ) -> tuple[int, Mock, Mock]:
        convert = Mock()
        snapshot_download = Mock(return_value=snapshot_result)
        mlx_lm = ModuleType("mlx_lm")
        mlx_lm.convert = convert
        huggingface_hub = ModuleType("huggingface_hub")
        huggingface_hub.snapshot_download = snapshot_download

        with (
            patch.object(convert_to_mlx, "parse_args", return_value=args),
            patch.object(convert_to_mlx, "validate"),
            patch.dict(
                sys.modules,
                {"mlx_lm": mlx_lm, "huggingface_hub": huggingface_hub},
            ),
        ):
            result = convert_to_mlx.main()

        return result, convert, snapshot_download

    def test_converts_local_source_without_downloading(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source"
            source.mkdir()
            output = root / "nested" / "output"
            args = argparse.Namespace(
                model=str(source),
                output=output,
                revision="main",
                bits=4,
                group_size=64,
                no_quantize=False,
                upload_repo=None,
                trust_remote_code=False,
            )

            result, convert, snapshot_download = self.run_main(args)

            self.assertEqual(result, 0)
            self.assertTrue(output.parent.is_dir())
            snapshot_download.assert_not_called()
            convert.assert_called_once_with(
                str(source),
                mlx_path=str(output),
                quantize=True,
                q_bits=4,
                q_group_size=64,
                upload_repo=None,
                trust_remote_code=False,
            )

    def test_downloads_remote_source_and_forwards_options(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "output"
            args = argparse.Namespace(
                model="org/model",
                output=output,
                revision="v2",
                bits=8,
                group_size=128,
                no_quantize=True,
                upload_repo="org/converted",
                trust_remote_code=True,
            )

            result, convert, snapshot_download = self.run_main(args)

            self.assertEqual(result, 0)
            snapshot_download.assert_called_once_with(
                repo_id="org/model", revision="v2"
            )
            convert.assert_called_once_with(
                "/cached/model",
                mlx_path=str(output),
                quantize=False,
                q_bits=8,
                q_group_size=128,
                upload_repo="org/converted",
                trust_remote_code=True,
            )


if __name__ == "__main__":
    unittest.main()
