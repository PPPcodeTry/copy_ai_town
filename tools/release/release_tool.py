#!/usr/bin/env python3
"""Prepare, package, and verify My AI Town release builds."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
import zipfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


VERSION_PATTERN = re.compile(
    r"^(?P<major>0|[1-9]\d*)\."
    r"(?P<minor>0|[1-9]\d*)\."
    r"(?P<patch>0|[1-9]\d*)"
    r"(?:-(?P<channel>alpha|beta|rc)\.(?P<number>[1-9]\d*))?$"
)
PLATFORMS = ("windows", "macos")


class ReleaseError(RuntimeError):
    """A release input or artifact does not satisfy the release contract."""


@dataclass(frozen=True)
class ReleaseVersion:
    text: str
    major: int
    minor: int
    patch: int
    channel: str
    prerelease_number: int

    @property
    def tag(self) -> str:
        return f"v{self.text}"

    @property
    def is_prerelease(self) -> bool:
        return self.channel != "stable"

    @property
    def native_version(self) -> str:
        revision = self.prerelease_number if self.is_prerelease else 0
        return f"{self.major}.{self.minor}.{self.patch}.{revision}"

    @property
    def short_version(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"


def parse_version(raw: str) -> ReleaseVersion:
    text = raw.strip()
    match = VERSION_PATTERN.fullmatch(text)
    if match is None:
        raise ReleaseError(
            "版本号必须是 x.y.z，或 x.y.z-alpha.N / beta.N / rc.N。"
        )
    channel = match.group("channel") or "stable"
    number = int(match.group("number") or 0)
    return ReleaseVersion(
        text=text,
        major=int(match.group("major")),
        minor=int(match.group("minor")),
        patch=int(match.group("patch")),
        channel=channel,
        prerelease_number=number,
    )


def read_version(repo_root: Path) -> ReleaseVersion:
    version_file = repo_root / "VERSION"
    if not version_file.is_file():
        raise ReleaseError(f"缺少版本文件：{version_file}")
    return parse_version(version_file.read_text(encoding="utf-8"))


def validate_source_contract(repo_root: Path) -> ReleaseVersion:
    version = read_version(repo_root)
    project_file = repo_root / "game/project.godot"
    changelog = repo_root / "更新日志.md"
    if not project_file.is_file() or not changelog.is_file():
        raise ReleaseError("源码必须同时包含 game/project.godot 和 更新日志.md。")
    project = project_file.read_text(encoding="utf-8")
    if re.search(r"^config/(?:version|channel)\s*=", project, re.MULTILINE):
        raise ReleaseError("开发源码不得固化发行版本；版本只允许来自根目录 VERSION。")
    if not changelog.read_text(encoding="utf-8").strip():
        raise ReleaseError("更新日志.md 不能为空。")
    return version


def _replace_key_in_section(
    text: str,
    section: str,
    key: str,
    value: str,
) -> str:
    section_start = text.find(f"[{section}]")
    if section_start < 0:
        raise ReleaseError(f"缺少配置段：[{section}]")
    next_section = text.find("\n[", section_start + len(section) + 2)
    section_end = len(text) if next_section < 0 else next_section + 1
    block = text[section_start:section_end]
    line = f'{key}="{value}"'
    pattern = re.compile(rf"^{re.escape(key)}=.*$", re.MULTILINE)
    if pattern.search(block):
        block = pattern.sub(line, block, count=1)
    else:
        header_end = block.find("\n")
        if header_end < 0:
            block += f"\n{line}\n"
        else:
            block = block[: header_end + 1] + f"{line}\n" + block[header_end + 1 :]
    return text[:section_start] + block + text[section_end:]


def inject_project_metadata(project_file: Path, version: ReleaseVersion) -> None:
    text = project_file.read_text(encoding="utf-8")
    text = _replace_key_in_section(text, "application", "config/version", version.text)
    text = _replace_key_in_section(text, "application", "config/channel", version.channel)
    project_file.write_text(text, encoding="utf-8")


def _preset_index(text: str, preset_name: str) -> str:
    pattern = re.compile(
        rf"^\[preset\.(\d+)\]\n(?:(?!^\[).)*?^name=\"{re.escape(preset_name)}\"$",
        re.MULTILINE | re.DOTALL,
    )
    match = pattern.search(text)
    if match is None:
        raise ReleaseError(f"找不到导出预设：{preset_name}")
    return match.group(1)


def inject_native_versions(presets_file: Path, version: ReleaseVersion) -> None:
    text = presets_file.read_text(encoding="utf-8")
    windows_index = _preset_index(text, "Windows Desktop")
    macos_index = _preset_index(text, "macOS")
    for key in ("application/file_version", "application/product_version"):
        text = _replace_key_in_section(
            text,
            f"preset.{windows_index}.options",
            key,
            version.native_version,
        )
    text = _replace_key_in_section(
        text,
        f"preset.{macos_index}.options",
        "application/short_version",
        version.short_version,
    )
    text = _replace_key_in_section(
        text,
        f"preset.{macos_index}.options",
        "application/version",
        version.native_version,
    )
    presets_file.write_text(text, encoding="utf-8")


def build_info(
    version: ReleaseVersion,
    commit: str,
    build_date: str | None = None,
) -> dict[str, object]:
    clean_commit = commit.strip()
    if not re.fullmatch(r"[0-9a-fA-F]{7,40}", clean_commit):
        raise ReleaseError("commit 必须是 7 到 40 位十六进制 Git 提交号。")
    if build_date is None:
        build_date = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    return {
        "schemaVersion": 1,
        "version": version.text,
        "tag": version.tag,
        "channel": version.channel,
        "commit": clean_commit.lower(),
        "buildDate": build_date,
    }


def prepare(repo_root: Path, commit: str, build_date: str | None = None) -> dict[str, object]:
    version = read_version(repo_root)
    inject_project_metadata(repo_root / "game/project.godot", version)
    inject_native_versions(repo_root / "game/export_presets.cfg", version)
    info = build_info(version, commit, build_date)
    output = repo_root / "game/build_info.json"
    output.write_text(
        json.dumps(info, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return info


def _archive_root(version: ReleaseVersion, platform: str) -> str:
    suffix = "windows-x86_64" if platform == "windows" else "macos-universal"
    return f"my-ai-town-{version.tag}-{suffix}"


def _copy_zip_entry(
    source: zipfile.ZipFile,
    destination: zipfile.ZipFile,
    entry: zipfile.ZipInfo,
    prefix: str,
) -> None:
    copied = zipfile.ZipInfo(f"{prefix}/{entry.filename}", date_time=entry.date_time)
    copied.compress_type = entry.compress_type
    copied.comment = entry.comment
    copied.extra = entry.extra
    copied.create_system = entry.create_system
    copied.external_attr = entry.external_attr
    copied.internal_attr = entry.internal_attr
    copied.flag_bits = entry.flag_bits
    if entry.is_dir():
        destination.writestr(copied, b"")
    else:
        with source.open(entry, "r") as source_file:
            with destination.open(copied, "w") as destination_file:
                shutil.copyfileobj(source_file, destination_file, length=1024 * 1024)


def package_release(
    repo_root: Path,
    platform: str,
    input_path: Path,
    output_path: Path,
) -> None:
    if platform not in PLATFORMS:
        raise ReleaseError(f"未知平台：{platform}")
    version = read_version(repo_root)
    changelog = repo_root / "更新日志.md"
    build_info_file = repo_root / "game/build_info.json"
    for required in (changelog, build_info_file):
        if not required.is_file():
            raise ReleaseError(f"打包缺少必需文件：{required}")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    root = _archive_root(version, platform)
    with zipfile.ZipFile(output_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        if platform == "windows":
            if not input_path.is_dir():
                raise ReleaseError(f"Windows 导出目录不存在：{input_path}")
            files = sorted(path for path in input_path.rglob("*") if path.is_file())
            if not files:
                raise ReleaseError("Windows 导出目录为空。")
            for path in files:
                archive.write(path, f"{root}/{path.relative_to(input_path).as_posix()}")
        else:
            if not input_path.is_file():
                raise ReleaseError(f"macOS 导出压缩包不存在：{input_path}")
            with zipfile.ZipFile(input_path) as source:
                for entry in source.infolist():
                    _copy_zip_entry(source, archive, entry, root)
        archive.write(changelog, f"{root}/更新日志.md")
        archive.write(build_info_file, f"{root}/build-info.json")
    verify_archive(output_path, platform, version.text)


def verify_archive(archive_path: Path, platform: str, expected_version: str) -> None:
    if platform not in PLATFORMS:
        raise ReleaseError(f"未知平台：{platform}")
    if not archive_path.is_file():
        raise ReleaseError(f"发行包不存在：{archive_path}")
    version = parse_version(expected_version)
    root = _archive_root(version, platform)
    with zipfile.ZipFile(archive_path) as archive:
        names = archive.namelist()
        required = {f"{root}/更新日志.md", f"{root}/build-info.json"}
        missing = required.difference(names)
        if missing:
            raise ReleaseError(f"发行包缺少：{', '.join(sorted(missing))}")
        if platform == "windows":
            has_executable = any(
                name.startswith(f"{root}/") and name.lower().endswith(".exe")
                for name in names
            )
            has_pck = any(
                name.startswith(f"{root}/") and name.lower().endswith(".pck")
                for name in names
            )
            if not has_executable or not has_pck:
                raise ReleaseError("Windows 发行包必须同时包含 .exe 和 .pck。")
        else:
            has_app_binary = any(
                name.startswith(f"{root}/") and ".app/Contents/MacOS/" in name
                for name in names
            )
            if not has_app_binary:
                raise ReleaseError("macOS 发行包缺少 .app/Contents/MacOS 下的程序。")
        info = json.loads(archive.read(f"{root}/build-info.json"))
        valid_commit = re.fullmatch(r"[0-9a-f]{7,40}", str(info.get("commit", "")))
        if (
            info.get("schemaVersion") != 1
            or info.get("version") != version.text
            or info.get("tag") != version.tag
            or info.get("channel") != version.channel
            or valid_commit is None
            or not str(info.get("buildDate", "")).strip()
        ):
            raise ReleaseError("发行包中的 build-info.json 与 VERSION 不一致。")


def generate_checksums(directory: Path, output_path: Path) -> None:
    archives = sorted(directory.glob("*.zip"))
    if not archives:
        raise ReleaseError(f"没有可生成校验和的 zip：{directory}")
    lines = []
    for archive in archives:
        digest_builder = hashlib.sha256()
        with archive.open("rb") as archive_file:
            while chunk := archive_file.read(1024 * 1024):
                digest_builder.update(chunk)
        digest = digest_builder.hexdigest()
        lines.append(f"{digest}  {archive.name}")
    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def generate_release_notes(repo_root: Path, output_path: Path) -> None:
    version = read_version(repo_root)
    changelog = (repo_root / "更新日志.md").read_text(encoding="utf-8")
    match = re.search(
        r"^## \d{4} 年.+?(?=^## \d{4} 年|\Z)",
        changelog,
        re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise ReleaseError("更新日志中没有可用于发行说明的更新章节。")
    notes = (
        f"# My AI Town {version.tag}\n\n"
        f"{match.group(0).strip()}\n\n"
        "## 下载说明\n\n"
        "- 这是供人工验收的预发行版本。\n"
        "- macOS 版本暂未进行 Apple 公证，首次打开时可能需要在系统设置中确认。\n"
        "- 可使用 `SHA256SUMS` 核对下载文件是否完整。\n"
    )
    output_path.write_text(notes, encoding="utf-8")


def _write_github_output(path: Path, version: ReleaseVersion) -> None:
    values = {
        "version": version.text,
        "tag": version.tag,
        "channel": version.channel,
        "prerelease": str(version.is_prerelease).lower(),
        "windows_asset": f"my-ai-town-{version.tag}-windows-x86_64.zip",
        "macos_asset": f"my-ai-town-{version.tag}-macos-universal.zip",
    }
    with path.open("a", encoding="utf-8", newline="\n") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    metadata = subparsers.add_parser("metadata")
    metadata.add_argument("--repo-root", type=Path, default=Path.cwd())
    metadata.add_argument("--github-output", type=Path)

    source_check = subparsers.add_parser("source-check")
    source_check.add_argument("--repo-root", type=Path, default=Path.cwd())

    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    prepare_parser.add_argument("--commit", required=True)
    prepare_parser.add_argument("--build-date")

    package_parser = subparsers.add_parser("package")
    package_parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    package_parser.add_argument("--platform", choices=PLATFORMS, required=True)
    package_parser.add_argument("--input", type=Path, required=True)
    package_parser.add_argument("--output", type=Path, required=True)

    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--archive", type=Path, required=True)
    verify_parser.add_argument("--platform", choices=PLATFORMS, required=True)
    verify_parser.add_argument("--version", required=True)

    checksum_parser = subparsers.add_parser("checksums")
    checksum_parser.add_argument("--directory", type=Path, required=True)
    checksum_parser.add_argument("--output", type=Path, required=True)

    notes_parser = subparsers.add_parser("release-notes")
    notes_parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    notes_parser.add_argument("--output", type=Path, required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "metadata":
            version = read_version(args.repo_root)
            if args.github_output:
                _write_github_output(args.github_output, version)
            print(json.dumps({"version": version.text, "tag": version.tag}))
        elif args.command == "source-check":
            version = validate_source_contract(args.repo_root)
            print(json.dumps({"version": version.text, "tag": version.tag}))
        elif args.command == "prepare":
            print(json.dumps(prepare(args.repo_root, args.commit, args.build_date)))
        elif args.command == "package":
            package_release(args.repo_root, args.platform, args.input, args.output)
        elif args.command == "verify":
            verify_archive(args.archive, args.platform, args.version)
        elif args.command == "checksums":
            generate_checksums(args.directory, args.output)
        elif args.command == "release-notes":
            generate_release_notes(args.repo_root, args.output)
    except (OSError, ValueError, zipfile.BadZipFile, json.JSONDecodeError, ReleaseError) as error:
        print(f"RELEASE_ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
