#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Regenerate the release manifest using only known project source directories."""
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOP_LEVEL = (".gitattributes", ".gitignore", "install.sh", "README.md", "LICENSE", "SECURITY.md")
DIRECTORIES = (".github", "src", "tests", "tools", "docs")


def main():
    files = [ROOT / name for name in TOP_LEVEL]
    for directory in DIRECTORIES:
        for path in (ROOT / directory).rglob("*"):
            relative = path.relative_to(ROOT)
            if (path.is_file() and not path.is_symlink()
                    and "__pycache__" not in relative.parts
                    and path.suffix not in (".pyc", ".pyo", ".tmp")
                    and not path.name.startswith(".")):
                files.append(path)
    lines = []
    for path in sorted(files, key=lambda p: p.relative_to(ROOT).as_posix()):
        if path.is_symlink() or not path.is_file():
            raise SystemExit(f"Expected a regular release file: {path.name}")
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        lines.append(digest + "  " + path.relative_to(ROOT).as_posix())
    with (ROOT / "SHA256SUMS").open("w", encoding="utf-8", newline="\n") as stream:
        stream.write("\n".join(lines) + "\n")
    print(f"Wrote SHA256SUMS for {len(lines)} release files.")


if __name__ == "__main__":
    main()
