#!/usr/bin/env python3

from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
OCCLUSION_LAYER = REPO_ROOT / "game/world/runtime/MapRuntimeOcclusionLayer.gd"
DOUBLE_TEXTURE_MULTIPLY = "texture(TEXTURE, UV) * COLOR"


def main() -> int:
    source = OCCLUSION_LAYER.read_text(encoding="utf-8")
    if "discard;" not in source:
        print("FOREGROUND_SHADER_CHECK_FAILED: clipping discard is missing")
        return 1
    if DOUBLE_TEXTURE_MULTIPLY in source:
        print("FOREGROUND_SHADER_CHECK_FAILED: foreground texture is multiplied twice")
        return 1
    print("FOREGROUND_SHADER_CHECK_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
