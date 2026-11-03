#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Rebuild the single-file installer with Python's standard library only."""
import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = (
    ("src/pve-sensors-agent.py", "pve-sensors-agent.py"),
    ("src/pve-sensors.service", "pve-sensors.service"),
    ("src/pve-sensors.defaults", "pve-sensors.defaults"),
    ("src/web/pve-sensors.html", "pve-sensors.html"),
    ("src/web/pve-sensors.css", "pve-sensors.css"),
    ("src/web/pve-sensors.js", "pve-sensors.js"),
)


def build():
    template = (ROOT / "src/install.template.sh").read_text(encoding="utf-8")
    sections = []
    for number, (source, destination) in enumerate(FILES, 1):
        text = (ROOT / source).read_text(encoding="utf-8")
        marker = f"PVE_SENSORS_EMBEDDED_FILE_{number}_END"
        if marker in text.splitlines():
            raise ValueError("Heredoc delimiter occurs in source")
        sections.append(f'  cat > "$target/{destination}" <<\'{marker}\'\n{text.rstrip()}\n{marker}')
    if template.count("@@EMBEDDED_PAYLOAD@@") != 1:
        raise ValueError("Expected exactly one payload marker")
    return template.replace("@@EMBEDDED_PAYLOAD@@", "\n".join(sections))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    output = ROOT / "install.sh"
    result = build()
    if args.check:
        if output.read_text(encoding="utf-8") != result:
            raise SystemExit("install.sh is out of date. Run python3 tools/build_installer.py")
        print("Installer matches its readable source files.")
    else:
        with output.open("w", encoding="utf-8", newline="\n") as stream:
            stream.write(result)
        output.chmod(0o755)
        print("Built install.sh")


if __name__ == "__main__":
    main()
