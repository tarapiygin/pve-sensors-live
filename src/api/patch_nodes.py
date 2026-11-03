#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Add/remove one marked registration in Proxmox's node API; no update hooks."""
import argparse
import re
from pathlib import Path

BEGIN = "# BEGIN PVE SENSORS LIVE\n"
END = "# END PVE SENSORS LIVE\n"
BLOCK = BEGIN + """use PVE::API2::PveSensors;
__PACKAGE__->register_method({
    subclass => 'PVE::API2::PveSensors',
    path => 'sensors',
});
""" + END


def patch(text, remove=False):
    if BEGIN in text or END in text:
        if text.count(BEGIN) != 1 or text.count(END) != 1 or BLOCK not in text:
            raise ValueError("Changed Sensors registration; review Nodes.pm manually")
        text = text.replace(BLOCK, "", 1)
    if remove:
        return text
    # Scope the anchor to Nodeinfo, not the second package in Nodes.pm.
    package = "package PVE::API2::Nodes::Nodeinfo;"
    if text.count(package) != 1:
        raise ValueError("Unsupported Nodes.pm: Nodeinfo package not found uniquely")
    start = text.index(package) + len(package)
    end = text.find("\npackage ", start)
    end = len(text) if end == -1 else end
    section = text[start:end]
    anchor = "use base qw(PVE::RESTHandler);\n"
    if section.count(anchor) != 1 or re.search(r"path\s*=>\s*['\"]sensors['\"]", section):
        raise ValueError("Unsupported Nodes.pm: ambiguous anchor or sensors route already exists")
    return text[:start] + section.replace(anchor, anchor + BLOCK, 1) + text[end:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--remove", action="store_true")
    args = parser.parse_args()
    try:
        result = patch(args.source.read_text(), args.remove)
    except ValueError as exc:
        parser.exit(1, f"{exc}\n")
    args.destination.write_text(result)


if __name__ == "__main__":
    main()
