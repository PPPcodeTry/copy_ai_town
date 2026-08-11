#!/usr/bin/env python3

from __future__ import annotations

import json
import stat
import tempfile
import unittest
import zipfile
from pathlib import Path

import release_tool


class ReleaseToolTest(unittest.TestCase):
    def test_version_contract(self) -> None:
        beta = release_tool.parse_version("0.1.0-beta.1\n")
        self.assertEqual(beta.tag, "v0.1.0-beta.1")
        self.assertEqual(beta.native_version, "0.1.0.1")
        self.assertEqual(beta.short_version, "0.1.0")
        self.assertTrue(beta.is_prerelease)
        stable = release_tool.parse_version("1.2.3")
        self.assertEqual(stable.native_version, "1.2.3.0")
        self.assertFalse(stable.is_prerelease)
        invalid_versions = (
            "v1.2.3",
            "1.2",
            "01.2.3",
            "1.2.3-preview.1",
            "1.2.3-beta.0",
        )
        for invalid in invalid_versions:
            with self.subTest(invalid=invalid), self.assertRaises(release_tool.ReleaseError):
                release_tool.parse_version(invalid)

    def test_prepare_injects_only_release_copy(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            root = Path(raw_temp)
            game = root / "game"
            game.mkdir()
            (root / "VERSION").write_text("0.1.0-beta.1\n", encoding="utf-8")
            (game / "project.godot").write_text(
                '[application]\nconfig/name="Town"\n\n[display]\nmode="windowed"\n',
                encoding="utf-8",
            )
            (game / "export_presets.cfg").write_text(
                '[preset.7]\nname="Windows Desktop"\n\n[preset.7.options]\n'
                'application/file_version="1.0.0.0"\n'
                'application/product_version="1.0.0.0"\n\n'
                '[preset.9]\nname="macOS"\n\n[preset.9.options]\n'
                'application/short_version="1.0.0"\napplication/version="1.0.0"\n',
                encoding="utf-8",
            )
            info = release_tool.prepare(root, "abcdef1234567", "2026-08-11T00:00:00+00:00")
            project = (game / "project.godot").read_text(encoding="utf-8")
            presets = (game / "export_presets.cfg").read_text(encoding="utf-8")
            self.assertEqual(project.count("config/version="), 1)
            self.assertIn('config/version="0.1.0-beta.1"', project)
            self.assertIn('config/channel="beta"', project)
            self.assertIn('application/file_version="0.1.0.1"', presets)
            self.assertIn('application/short_version="0.1.0"', presets)
            self.assertIn('application/version="0.1.0.1"', presets)
            self.assertEqual(info["tag"], "v0.1.0-beta.1")
            self.assertEqual(
                json.loads((game / "build_info.json").read_text(encoding="utf-8"))["commit"],
                "abcdef1234567",
            )

    def test_source_contract_rejects_committed_release_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            root = Path(raw_temp)
            (root / "game").mkdir()
            (root / "VERSION").write_text("0.1.0-beta.1\n", encoding="utf-8")
            (root / "更新日志.md").write_text("# 更新日志\n", encoding="utf-8")
            project = root / "game/project.godot"
            project.write_text('[application]\nconfig/name="Town"\n', encoding="utf-8")
            self.assertEqual(release_tool.validate_source_contract(root).text, "0.1.0-beta.1")
            project.write_text(
                '[application]\nconfig/name="Town"\nconfig/version="0.1.0-beta.1"\n',
                encoding="utf-8",
            )
            with self.assertRaises(release_tool.ReleaseError):
                release_tool.validate_source_contract(root)

    def _release_root(self, raw_temp: str) -> Path:
        root = Path(raw_temp)
        (root / "game").mkdir()
        (root / "VERSION").write_text("0.1.0-beta.1\n", encoding="utf-8")
        (root / "更新日志.md").write_text("# 日志\n", encoding="utf-8")
        (root / "game/build_info.json").write_text(
            json.dumps({
                "schemaVersion": 1,
                "version": "0.1.0-beta.1",
                "tag": "v0.1.0-beta.1",
                "channel": "beta",
                "commit": "abcdef1",
                "buildDate": "2026-08-11T00:00:00+00:00",
            }),
            encoding="utf-8",
        )
        return root

    def test_windows_package_contains_player_files_and_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            root = self._release_root(raw_temp)
            export = root / "export/windows"
            export.mkdir(parents=True)
            (export / "my-ai-town.exe").write_bytes(b"exe")
            (export / "my-ai-town.pck").write_bytes(b"pck")
            output = root / "dist/windows.zip"
            release_tool.package_release(root, "windows", export, output)
            release_tool.verify_archive(output, "windows", "0.1.0-beta.1")
            with zipfile.ZipFile(output) as archive:
                names = archive.namelist()
            self.assertTrue(any(name.endswith("/更新日志.md") for name in names))
            self.assertTrue(any(name.endswith("/build-info.json") for name in names))

    def test_macos_package_preserves_executable_mode(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            root = self._release_root(raw_temp)
            source = root / "macos-source.zip"
            executable = zipfile.ZipInfo("My AI Town.app/Contents/MacOS/My AI Town")
            executable.create_system = 3
            executable.external_attr = (stat.S_IFREG | 0o755) << 16
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr(executable, b"binary")
            output = root / "dist/macos.zip"
            release_tool.package_release(root, "macos", source, output)
            release_tool.verify_archive(output, "macos", "0.1.0-beta.1")
            with zipfile.ZipFile(output) as archive:
                copied = next(
                    entry
                    for entry in archive.infolist()
                    if ".app/Contents/MacOS/" in entry.filename
                )
            self.assertEqual((copied.external_attr >> 16) & 0o777, 0o755)

    def test_verify_rejects_incomplete_package(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            archive_path = Path(raw_temp) / "bad.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("unrelated.txt", "bad")
            with self.assertRaises(release_tool.ReleaseError):
                release_tool.verify_archive(archive_path, "windows", "0.1.0-beta.1")

    def test_checksums_are_sorted_and_sha256(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            root = Path(raw_temp)
            (root / "b.zip").write_bytes(b"b")
            (root / "a.zip").write_bytes(b"a")
            output = root / "SHA256SUMS"
            release_tool.generate_checksums(root, output)
            lines = output.read_text(encoding="utf-8").splitlines()
            self.assertTrue(lines[0].endswith("  a.zip"))
            self.assertEqual(len(lines[0].split()[0]), 64)

    def test_release_notes_include_full_latest_date_only(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            root = Path(raw_temp)
            (root / "VERSION").write_text("0.1.0-beta.1\n", encoding="utf-8")
            (root / "更新日志.md").write_text(
                "# 更新日志\n\n"
                "## 2026 年 8 月 11 日更新\n\n最新摘要\n\n"
                "## 测试版本与下载\n\n最新细节\n\n"
                "## 2026 年 8 月 10 日更新\n\n旧内容\n",
                encoding="utf-8",
            )
            output = root / "notes.md"
            release_tool.generate_release_notes(root, output)
            notes = output.read_text(encoding="utf-8")
            self.assertIn("最新摘要", notes)
            self.assertIn("最新细节", notes)
            self.assertNotIn("旧内容", notes)


if __name__ == "__main__":
    unittest.main()
