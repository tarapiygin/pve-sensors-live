#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read lm-sensors without privileges and atomically publish allowlisted metrics.

Only Python's standard library is used. There is no HTTP server, network access,
fan control, sensor configuration, persistent history, or host identification.
"""

import argparse
import json
import math
import os
import re
import secrets
import signal
import subprocess
import sys
import tempfile
import threading
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

VERSION = "2.0.0"
SENSORS = "/usr/bin/sensors"
DEFAULT_OUTPUT = Path("/run/pve-sensors/metrics.json")
READ_TIMEOUT = 2.0
MAX_METRICS = 512
INPUT_PATTERN = re.compile(r"^(temp|fan)([0-9]+)_input$")
STOP = threading.Event()


def finite(value):
    """Reject bool, NaN, infinity, and values that cannot be represented."""
    if isinstance(value, bool) or not isinstance(value, (float, int)):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def interval_value(value):
    try:
        interval = float(value)
    except (TypeError, ValueError) as exc:
        raise argparse.ArgumentTypeError("interval must be a number") from exc
    if not math.isfinite(interval) or not 0.1 <= interval <= 60.0:
        raise argparse.ArgumentTypeError("interval must be between 0.1 and 60 seconds")
    return interval


def driver_group(chip):
    """Classify drivers internally; never publish chip names or bus addresses."""
    if chip.startswith(("coretemp-", "k10temp-", "zenpower-", "cpu_thermal-")):
        return "cpu", "CPU"
    if chip.startswith("nvme-"):
        return "storage", "NVMe"
    if chip.startswith("drivetemp-"):
        return "storage", "Drive"
    if chip.startswith(("amdgpu-", "nouveau-")):
        return "gpu", "GPU"
    if chip.startswith(("iwlwifi_", "iwlwifi-")):
        return "system", "Wi-Fi"
    if chip.startswith("acpitz-"):
        return "system", "ACPI"
    return "system", "Sensor"


def safe_label(family, index, label, channel, kind):
    """Generate labels, rather than trusting administrator-supplied text."""
    if kind == "fan":
        return f"Fan {index}.{channel}", "fan"
    if family == "CPU":
        core = re.fullmatch(r"Core ([0-9]{1,4})", label)
        if core:
            return f"CPU {index} / Core {int(core.group(1))}", "core"
        if re.fullmatch(r"Package id [0-9]{1,4}", label):
            return f"CPU {index} / Package", "package"
        if label in ("Tdie", "Tctl"):
            return f"CPU {index} / {label}", "package"
        ccd = re.fullmatch(r"Tccd([0-9]{1,4})", label)
        if ccd:
            return f"CPU {index} / CCD {int(ccd.group(1))}", "cpu"
        return f"CPU {index} / Temperature {channel}", "cpu"
    if family == "NVMe" and label == "Composite":
        return f"NVMe {index} / Composite", "composite"
    return f"{family} {index} / Temperature {channel}", "temperature"


def extract_metrics(raw):
    if not isinstance(raw, dict):
        raise ValueError("expected an object from sensors -j")
    metrics = []
    counters = Counter()
    for chip_name, chip in sorted(raw.items()):
        if not isinstance(chip_name, str) or not isinstance(chip, dict):
            continue
        category, family = driver_group(chip_name)
        counters[family] += 1
        device_index = counters[family]
        # A second ordinal makes IDs unique even for fans on different families.
        chip_index = sum(counters.values())
        seen = set()
        for label, fields in sorted(chip.items()):
            if not isinstance(fields, dict):
                continue
            for key, value in sorted(fields.items()):
                match = INPUT_PATTERN.fullmatch(key)
                if not match or key in seen or not finite(value):
                    continue
                kind, number = match.groups()
                channel = int(number)
                if not 0 <= channel <= 9999:
                    continue
                if kind == "temp" and not -100 <= value <= 200:
                    continue
                if kind == "fan" and not 0 <= value <= 100000:
                    continue
                seen.add(key)
                name, role = safe_label(family, device_index if kind == "temp" else chip_index,
                                        label, channel, kind)
                metric = {
                    "id": f"sensor-{chip_index}-{kind}{channel}",
                    "category": "fans" if kind == "fan" else category,
                    "name": name,
                    "role": role,
                    "value": round(value, 2),
                    "unit": "RPM" if kind == "fan" else "°C",
                }
                prefix = f"{kind}{number}"
                if kind == "temp":
                    for source, destination in (("max", "max"), ("crit", "critical")):
                        limit = fields.get(f"{prefix}_{source}")
                        if finite(limit) and 0 < limit <= 200:
                            metric[destination] = round(limit, 2)
                    # Broken firmware can report inconsistent thresholds.
                    if metric.get("max", -math.inf) > metric.get("critical", math.inf):
                        metric.pop("max", None)
                metrics.append(metric)
                if len(metrics) >= MAX_METRICS:
                    return metrics
    return metrics


def read_metrics():
    # Fixed argv, no shell, no user-supplied command, and no sensor writes.
    result = subprocess.run(
        [SENSORS, "-j"], check=True, capture_output=True, text=True,
        timeout=READ_TIMEOUT, env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C"},
    )
    metrics = extract_metrics(json.loads(result.stdout))
    if not metrics:
        raise ValueError("no valid temperature or fan readings")
    return metrics


def publish(payload, output):
    """Replace a complete JSON file; pveproxy cannot observe a partial write."""
    fd, temporary = tempfile.mkstemp(prefix=".metrics-", suffix=".tmp", dir=output.parent)
    try:
        os.fchmod(fd, 0o644)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
            stream.write("\n")
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def run(interval, output):
    # Random per-process identifier; not a host ID, credential, or persistent ID.
    session = secrets.token_hex(8)
    sequence = 0
    next_tick = time.monotonic()
    last_error = None
    last_error_log = 0.0
    signal.signal(signal.SIGTERM, lambda *_: STOP.set())
    signal.signal(signal.SIGINT, lambda *_: STOP.set())
    while not STOP.is_set():
        started = time.monotonic()
        try:
            metrics = read_metrics()
            sequence += 1
            payload = {
                "version": VERSION,
                "updated_at": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
                "session": session,
                "sequence": sequence,
                "sample_interval_ms": round(interval * 1000),
                "collection_ms": round((time.monotonic() - started) * 1000, 2),
                "metrics": metrics,
            }
            publish(payload, output)
            if last_error is not None:
                print("Sensor readings recovered.", file=sys.stderr, flush=True)
            last_error = None
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            # Do not log raw sensor output or hardware identity. Leave the old
            # timestamp untouched so the UI identifies stale data correctly.
            error_kind = type(exc).__name__
            now = time.monotonic()
            if error_kind != last_error or now - last_error_log >= 60:
                print(f"Sensor collection failed ({error_kind}); retaining the last snapshot.",
                      file=sys.stderr, flush=True)
                last_error_log = now
            last_error = error_kind
        next_tick += interval
        now = time.monotonic()
        if next_tick <= now:
            # Skip missed deadlines, rather than running a catch-up burst.
            next_tick = now + interval
        STOP.wait(next_tick - now)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interval", type=interval_value,
                        default=os.environ.get("PVE_SENSORS_INTERVAL", "0.5"))
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--check", action="store_true", help="read once; print only a count")
    parser.add_argument("--validate-stdin", action="store_true", help="validate sensors -j from stdin")
    parser.add_argument("--version", action="version", version=VERSION)
    args = parser.parse_args()
    if args.check or args.validate_stdin:
        try:
            metrics = extract_metrics(json.load(sys.stdin)) if args.validate_stdin else read_metrics()
            if not metrics:
                raise ValueError("no valid temperature or fan readings")
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            print(f"Sensor preflight failed ({type(exc).__name__}). Check sensors -j locally.",
                  file=sys.stderr)
            return 1
        print(f"Sensor preflight: {len(metrics)} valid metrics.")
        return 0
    if not args.output.parent.is_dir():
        parser.error("output directory must already exist (normally created by systemd)")
    return run(args.interval, args.output)


if __name__ == "__main__":
    sys.exit(main())
