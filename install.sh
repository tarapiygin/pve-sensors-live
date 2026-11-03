#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# PVE Sensors Live: a self-contained, auditable installer.
# All runtime source files are embedded as plain-text heredocs below.
# No remote script execution, source downloads, repository edits, or extra listeners.
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 022

VERSION=2.0.0
WEB=/usr/share/pve-manager/js
AGENT=/usr/local/libexec/pve-sensors-agent.py
UNIT=/etc/systemd/system/pve-sensors.service
CONFIG=/etc/default/pve-sensors
MARKER=/usr/local/share/pve-sensors/installed-version
RUNTIME=/run/pve-sensors/metrics.json
SERVICE=pve-sensors.service
NODES=/usr/share/perl5/PVE/API2/Nodes.pm
API=/usr/share/perl5/PVE/API2/PveSensors.pm
MODE=install
ASSUME_YES=no
SKIP_HTTP=no
INTERVAL=
EXTRACT_DIR=
STAGE=
BACKUP=
CHANGED=no
COMMITTED=no
OLD_ACTIVE=no
OLD_ENABLED=no
FILES=("$AGENT" "$UNIT" "$CONFIG" "$WEB/pve-sensors.html"
       "$WEB/pve-sensors.css" "$WEB/pve-sensors.js" "$API" "$MARKER")

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
PVE Sensors Live 2.0.0

Install or upgrade (run as root on the Proxmox VE host):
  bash install.sh
  bash install.sh --yes --interval 0.5

Other operations:
  bash install.sh --status
  bash install.sh --uninstall
  bash install.sh --uninstall --yes
  bash install.sh --extract ./extracted-source
  bash install.sh --help

Options:
  --yes                 Accept the displayed installation/removal confirmations.
  --interval SECONDS    Poll interval: 0.1 to 60; default 0.5; preserve on upgrade.
  --skip-http-check     Skip only the HTTPS loopback test (restricted listeners).
  --extract DIRECTORY   Extract embedded sources only, without root or changes
                        outside a newly created directory. No packages installed.

Only lm-sensors is requested from your existing APT repositories when absent.
Python 3.9+, systemd and Debian base utilities must already be present on PVE.
Adds one node API registration and reloads pvedaemon/pveproxy. Guests stay running.
USAGE
}

set_mode() {
  [[ "$MODE" == install ]] || die 'Choose only one operation.'
  MODE="$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --yes|-y) ASSUME_YES=yes; shift ;;
    --skip-http-check) SKIP_HTTP=yes; shift ;;
    --interval)
      [[ $# -ge 2 ]] || die '--interval requires a value.'
      INTERVAL="$2"; shift 2 ;;
    --extract)
      [[ $# -ge 2 && -n "$2" ]] || die '--extract requires a new directory.'
      set_mode extract; EXTRACT_DIR="$2"; shift 2 ;;
    --uninstall) set_mode uninstall; shift ;;
    --status) set_mode status; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

write_payload() {
  local target="$1"
  cat > "$target/PveSensors.pm" <<'PVE_SENSORS_EMBEDDED_FILE_1_END'
# SPDX-License-Identifier: MIT
package PVE::API2::PveSensors;

use strict;
use warnings;
use JSON::PP qw(decode_json);
use PVE::Exception qw(raise);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Tools qw(file_get_contents);
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    name => 'snapshot',
    path => '',
    method => 'GET',
    description => 'Read the sanitized PVE Sensors Live snapshot.',
    proxyto => 'node',
    permissions => {
        check => ['perm', '/nodes/{node}', ['Sys.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => { node => get_standard_option('pve-node') },
    },
    returns => { type => 'object', additionalProperties => 1 },
    code => sub {
        # Collection and sanitization stay in the unprivileged agent. Never run
        # sensors, accept a filesystem path, or return raw read/decode errors.
        my $snapshot = eval {
            decode_json(file_get_contents('/run/pve-sensors/metrics.json'));
        };
        raise('Sensor snapshot unavailable', code => 503)
            if $@ || ref($snapshot) ne 'HASH' || ref($snapshot->{metrics}) ne 'ARRAY';
        return $snapshot;
    },
});

1;
PVE_SENSORS_EMBEDDED_FILE_1_END
  cat > "$target/patch_nodes.py" <<'PVE_SENSORS_EMBEDDED_FILE_2_END'
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
PVE_SENSORS_EMBEDDED_FILE_2_END
  cat > "$target/pve-sensors-agent.py" <<'PVE_SENSORS_EMBEDDED_FILE_3_END'
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
PVE_SENSORS_EMBEDDED_FILE_3_END
  cat > "$target/pve-sensors.service" <<'PVE_SENSORS_EMBEDDED_FILE_4_END'
# SPDX-License-Identifier: MIT
[Unit]
Description=PVE Sensors Live - unprivileged hardware sensor collector
After=local-fs.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
DynamicUser=yes
User=pve-sensors
Environment=PVE_SENSORS_INTERVAL=0.5
EnvironmentFile=-/etc/default/pve-sensors
ExecStart=/usr/bin/python3 -I -B -u /usr/local/libexec/pve-sensors-agent.py
Restart=on-failure
RestartSec=3
TimeoutStopSec=5
RuntimeDirectory=pve-sensors
RuntimeDirectoryMode=0755
UMask=0022
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/run/pve-sensors
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
PrivateTmp=yes
PrivateDevices=yes
PrivateNetwork=yes
RestrictAddressFamilies=AF_UNIX
CapabilityBoundingSet=
AmbientCapabilities=
RestrictSUIDSGID=yes
RestrictRealtime=yes
LockPersonality=yes
CPUAccounting=yes
MemoryAccounting=yes
MemoryMax=96M
TasksMax=16

[Install]
WantedBy=multi-user.target
PVE_SENSORS_EMBEDDED_FILE_4_END
  cat > "$target/pve-sensors.defaults" <<'PVE_SENSORS_EMBEDDED_FILE_5_END'
# SPDX-License-Identifier: MIT
# Poll interval in seconds: 0.1 to 60. Default: 0.5 (two reads per second).
# Faster polling does not make the hardware sensor update faster.
# Restart only pve-sensors.service after editing this file.
PVE_SENSORS_INTERVAL=0.5
PVE_SENSORS_EMBEDDED_FILE_5_END
  cat > "$target/pve-sensors.html" <<'PVE_SENSORS_EMBEDDED_FILE_6_END'
<!doctype html>
<!-- SPDX-License-Identifier: MIT -->
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; object-src 'none'">
  <meta name="referrer" content="no-referrer">
  <meta name="color-scheme" content="dark light">
  <title>PVE Sensors Live | Hardware temperatures</title>
  <link rel="stylesheet" href="./pve-sensors.css?v=2.0.0">
  <script src="./pve-sensors.js?v=2.0.0" defer></script>
</head>
<body>
  <header class="topbar">
    <div class="topbar-inner">
      <div class="brand"><span class="brand-mark" aria-hidden="true">°</span><span>PVE Sensors <span class="brand-muted">Live</span></span></div>
      <a class="back-link" href="/">Back to Proxmox ↗</a>
    </div>
  </header>
  <main class="layout">
    <div class="heading-row">
      <div>
        <p class="eyebrow">HARDWARE TELEMETRY · NO EXTRA SERVER</p>
        <h1>Your host, a little more visible.</h1>
        <p class="description">Live temperatures. One lightweight collector. History stays in this tab.</p>
      </div>
      <div class="live-block">
        <span id="connection" class="connection pending" role="status">Connecting</span>
        <span id="updated" class="updated">Waiting for a snapshot</span>
      </div>
    </div>
    <p id="demoBanner" class="demo-banner" hidden>SIMULATED PREVIEW · Not a real host or production measurements</p>
    <noscript><p class="notice">JavaScript is required to display live sensor readings.</p></noscript>
    <section class="hero-grid" aria-label="Primary temperatures">
      <article class="panel hero-card">
        <div class="hero-heading"><span class="sensor-symbol cpu-symbol">CPU</span><span id="cpuState" class="state neutral">No data</span></div>
        <p class="metric-label">Processor temperature</p>
        <div class="hero-value" id="cpuValue">—</div>
        <p class="metric-subtitle" id="cpuName">Waiting for a CPU sensor</p>
        <div class="meter" aria-hidden="true"><div id="cpuMeter" class="meter-fill neutral"></div></div>
        <p id="cpuLimits" class="limits">Sensor thresholds are not available</p>
      </article>
      <article class="panel hero-card">
        <div class="hero-heading"><span class="sensor-symbol nvme-symbol">SSD</span><span id="nvmeState" class="state neutral">No data</span></div>
        <p class="metric-label">Storage temperature</p>
        <div class="hero-value" id="nvmeValue">—</div>
        <p class="metric-subtitle" id="nvmeName">Waiting for a storage sensor</p>
        <div class="meter" aria-hidden="true"><div id="nvmeMeter" class="meter-fill neutral"></div></div>
        <p id="nvmeLimits" class="limits">Sensor thresholds are not available</p>
      </article>
    </section>
    <section class="panel chart-panel" aria-labelledby="chartTitle">
      <div class="chart-head">
        <div>
          <h2 id="chartTitle">CPU temperature history</h2>
          <p class="chart-caption"><span id="sampling">500 ms target interval</span> · Session-only history</p>
        </div>
        <label class="source-control">Chart source <select id="cpuSource" aria-label="CPU sensor for chart"><option value="">Waiting for sensors</option></select></label>
      </div>
      <div class="chart-stats" aria-label="Chart statistics">
        <div><span>Current</span><strong id="chartCurrent">—</strong></div>
        <div><span>Session minimum</span><strong id="chartMin">—</strong></div>
        <div><span>Session maximum</span><strong id="chartMax">—</strong></div>
        <div><span>Elapsed</span><strong id="chartDuration">00:00</strong></div>
        <div><span>Unique snapshots</span><strong id="chartSamples">0</strong></div>
      </div>
      <div class="chart-canvas-wrap">
        <canvas id="cpuChart" class="chart-canvas" role="img" aria-label="CPU temperature since this page was opened"></canvas>
      </div>
      <p id="historyNote" class="chart-footnote">Reloading resets history. Hidden tabs pause polling. Gaps are not invented measurements.</p>
    </section>
    <section class="panel section-panel">
      <div class="section-heading"><h2>Processor sensors</h2><span class="section-note">Packages, cores and chiplets</span></div>
      <div id="cores" class="sensor-grid"><p class="empty">Waiting for readings…</p></div>
    </section>
    <section class="panel section-panel">
      <div class="section-heading"><h2>Storage &amp; other sensors</h2><span class="section-note">Read-only measurements</span></div>
      <div id="other" class="sensor-grid"><p class="empty">Waiting for readings…</p></div>
    </section>
    <footer>
      <p>Source: <code>sensors -j</code> · No telemetry · No external libraries · No server-side history</p>
      <p>Thresholds come from the sensor, not a safety guarantee. Readings require a Proxmox session and node Sys.Audit permission.</p>
    </footer>
  </main>
</body>
</html>
PVE_SENSORS_EMBEDDED_FILE_6_END
  cat > "$target/pve-sensors.css" <<'PVE_SENSORS_EMBEDDED_FILE_7_END'
/* SPDX-License-Identifier: MIT */
:root{color-scheme:dark light;font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",Arial,sans-serif;background:#111827;color:#eef2f7}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;background:radial-gradient(circle at 80% -15%,#1d3550 0,transparent 35%),#111827}
.topbar{border-bottom:1px solid #293448;background:#141c2acc}
.topbar-inner{max-width:1120px;margin:auto;min-height:68px;padding:0 24px;display:flex;align-items:center;justify-content:space-between;gap:12px}
.brand{display:flex;align-items:center;gap:12px;font-weight:700;font-size:15px}
.brand-mark{display:grid;place-items:center;width:32px;height:32px;border-radius:9px;background:#e87922;color:#fff;font-weight:800;font-size:20px}
.brand-muted{color:#9aa9bd;font-weight:500}
.back-link{color:#b6c6da;text-decoration:none;font-size:13px;padding:10px;border-radius:8px}
.back-link:hover{color:#fff;background:#25344a}
.layout{max-width:1120px;margin:0 auto;padding:39px 24px 36px}
.heading-row{display:flex;justify-content:space-between;align-items:flex-start;gap:25px;margin-bottom:25px}
.eyebrow{font-size:11px;letter-spacing:.14em;color:#e99550;font-weight:700;margin:0 0 10px}
h1{font-size:clamp(25px,3vw,35px);line-height:1.2;letter-spacing:-.04em;margin:0 0 11px;font-weight:730}
.description{font-size:14px;color:#a8b6c8;margin:0;line-height:1.55}
.live-block{display:flex;flex-direction:column;align-items:flex-end;gap:8px;min-width:165px}
.connection,.state{font-size:12px;font-weight:650;border:1px solid transparent;border-radius:999px;padding:7px 11px;white-space:nowrap}
.connection.ok,.state.normal{background:#123c34;color:#62e6b0;border-color:#22654f}
.connection.pending,.state.neutral{background:#273345;color:#a9b9ce;border-color:#37465a}
.connection.warning,.state.warning{background:#48351b;color:#ffc474;border-color:#755124}
.connection.danger,.state.critical{background:#4d252c;color:#ff8d97;border-color:#7d3840}
.updated{font-size:12px;color:#94a3b8;text-align:right}
.hero-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:18px;margin-bottom:19px}
.panel{border:1px solid #2a374a;background:linear-gradient(150deg,#202b3b,#1a2331);border-radius:15px;box-shadow:0 9px 30px #050b1626}
.hero-card{padding:24px 27px 23px}
.hero-heading{display:flex;justify-content:space-between;align-items:center;gap:10px;margin-bottom:24px}
.sensor-symbol{font-size:11px;letter-spacing:.04em;font-weight:850;display:grid;place-items:center;border-radius:10px;width:44px;height:39px}
.cpu-symbol{background:#293e5f;color:#84b5ff}
.nvme-symbol{background:#443351;color:#dcafff}
.metric-label{margin:0 0 4px;color:#b2c1d3;font-size:13px}
.hero-value{font-size:clamp(43px,6vw,66px);font-variant-numeric:tabular-nums;line-height:1.17;font-weight:720;letter-spacing:-.055em}
.metric-subtitle{color:#8f9fb4;font-size:12px;margin:2px 0 23px}
.meter{height:8px;border-radius:99px;background:#344257;overflow:hidden}
.meter-fill{height:100%;border-radius:99px;width:0;transition:width .35s;background:#61768d}
.meter-fill.normal{background:linear-gradient(90deg,#21bda0,#6bdbc2)}
.meter-fill.warning{background:#f6af4b}
.meter-fill.critical{background:#f26a75}
.limits{min-height:18px;color:#8f9fb4;font-size:12px;margin:13px 0 0}
.section-panel{padding:22px 25px 25px;margin-bottom:19px}
.section-heading{display:flex;align-items:baseline;justify-content:space-between;gap:12px;margin-bottom:19px}
h2{font-size:16px;letter-spacing:-.015em;margin:0;font-weight:680}
.section-note{font-size:12px;color:#879ab1}
.sensor-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}
.sensor-card{background:#151f2d;border:1px solid #2c3b4e;border-radius:11px;padding:18px 15px 15px;min-width:0}
.sensor-card[data-state="warning"]{border-color:#765126}
.sensor-card[data-state="critical"]{border-color:#873d46}
.sensor-name{color:#9bacbf;font-size:12px;overflow-wrap:anywhere;min-height:30px;line-height:1.4}
.sensor-value{font-size:27px;letter-spacing:-.035em;font-weight:720;font-variant-numeric:tabular-nums;margin-top:8px}
.sensor-value small{font-size:13px;font-weight:500;color:#a2b3c7;margin-left:4px}
.sensor-meta{font-size:11px;color:#8c9cb1;margin-top:9px;line-height:1.5;min-height:16px}
.empty{color:#91a0b5;font-size:13px;margin:8px 0}
footer{color:#7f91a9;font-size:11px;line-height:1.6;text-align:center;margin-top:28px}
code{font-family:ui-monospace,SFMono-Regular,Consolas,monospace}
@media(max-width:800px){.sensor-grid{grid-template-columns:repeat(2,minmax(0,1fr))}.heading-row{flex-direction:column}.live-block{align-items:flex-start}.updated{text-align:left}}
@media(max-width:560px){.layout{padding:25px 15px}.topbar-inner{padding:0 15px}.hero-grid{grid-template-columns:1fr}.hero-card{padding:21px}.section-panel{padding:18px}.sensor-grid{gap:9px}.sensor-card{padding:14px 12px}.sensor-value{font-size:23px}.brand-muted{display:none}}
@media(prefers-color-scheme:light){:root{background:#f3f5f8;color:#192533}body{background:radial-gradient(circle at 80% -15%,#e3edf8 0,transparent 40%),#f3f5f8}.topbar{background:#fff;border-color:#dce2eb}.brand-muted,.description{color:#607388}.back-link{color:#4f6074}.back-link:hover{color:#1c2939;background:#edf1f7}.panel{background:linear-gradient(145deg,#fff,#fbfcff);border-color:#dce3ed;box-shadow:0 6px 24px #22344b0a}.sensor-card{background:#f7f9fc;border-color:#e4e9f1}.metric-label,.section-note,.sensor-name{color:#607185}.metric-subtitle,.limits,.sensor-meta,.updated,.empty{color:#697d93}.sensor-value small{color:#607185}.meter{background:#e5eaf1}.connection.ok,.state.normal{background:#e5f8ef;color:#096948;border-color:#bde6d0}.connection.warning,.state.warning{background:#fff2dc;color:#8c5300;border-color:#f2d3a1}.connection.danger,.state.critical{background:#ffebed;color:#9d2636;border-color:#f4bcc5}.connection.pending,.state.neutral{background:#edf2f7;color:#5b6d82;border-color:#dbe3ec}.eyebrow{color:#ae5b16}footer{color:#8494a6}}

/* Live CPU history chart */
:root{
  --chart-grid:#334155;
  --chart-text:#94a3b8;
  --chart-line:#57bdff;
  --chart-area:rgba(66,171,255,.19);
}
.chart-panel{padding:24px 26px 19px;margin-bottom:19px}
.chart-head{display:flex;align-items:flex-start;justify-content:space-between;gap:14px}
.chart-head h2{font-size:17px}
.chart-caption{margin:7px 0 0;font-size:12px;color:#91a5bd;line-height:1.45}
.chart-samples{color:#8fb6d6;font-size:12px;border:1px solid #364c65;background:#1b3148;border-radius:99px;padding:6px 11px;white-space:nowrap}
.chart-stats{display:flex;flex-wrap:wrap;gap:26px;margin:22px 0 12px}
.chart-stats>div{display:flex;flex-direction:column;gap:6px}
.chart-stats span{font-size:11px;color:#8da0b7}
.chart-stats strong{font-size:18px;font-weight:680;font-variant-numeric:tabular-nums}
.chart-canvas-wrap{position:relative;min-width:0;width:100%;height:292px}
.chart-canvas{display:block;width:100%;height:100%;touch-action:pan-y}
.chart-footnote{color:#8da0b7;margin:13px 0 0;font-size:11px;line-height:1.5}
@media(max-width:560px){.chart-panel{padding:20px 12px 16px}.chart-head{flex-direction:column}.chart-stats{gap:17px;margin:17px 9px 11px}.chart-stats strong{font-size:16px}.chart-canvas-wrap{height:246px}.chart-footnote{margin-left:9px;margin-right:9px}}
@media(prefers-color-scheme:light){:root{--chart-grid:#dae4ef;--chart-text:#728298;--chart-line:#1a77bc;--chart-area:rgba(37,134,208,.13)}.chart-caption,.chart-stats span,.chart-footnote{color:#74869c}.chart-samples{color:#296b9e;background:#e8f3fa;border-color:#d1e7f6}}

/* Public release controls; all assets are served locally. */
.source-control{display:flex;flex-direction:column;gap:7px;font-size:11px;color:#94a3b8;min-width:170px}
select{border:1px solid #40536b;border-radius:8px;padding:8px 10px;background:#152234;color:#e1ebf7;font:inherit;font-size:12px;max-width:100%}
select:focus-visible,.back-link:focus-visible{outline:2px solid #57bdff;outline-offset:3px}
.demo-banner{border:1px solid #6d5b2e;background:#3c331e;color:#f9d997;font-size:11px;letter-spacing:.06em;padding:11px 14px;border-radius:8px;margin:0 0 18px}
[hidden]{display:none!important}
.notice{padding:16px;border:1px solid #ed9d38;border-radius:8px}
footer p{margin:5px 0}
body.data-stale .hero-value,body.data-stale .sensor-value{opacity:.55}
@media(max-width:560px){.source-control{width:100%}.section-heading{flex-wrap:wrap}.description{max-width:34em}.chart-stats{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:16px}.topbar-inner{gap:8px}.brand{font-size:14px}.back-link{font-size:12px;padding:8px 0}}
@media(prefers-color-scheme:light){select{background:#fff;border-color:#cad6e4;color:#23394f}.source-control{color:#607185}.demo-banner{background:#fff5dd;color:#7a5411;border-color:#edd7a9}}
@media(prefers-reduced-motion:reduce){.meter-fill{transition:none}}
PVE_SENSORS_EMBEDDED_FILE_7_END
  cat > "$target/pve-sensors.js" <<'PVE_SENSORS_EMBEDDED_FILE_8_END'
/* SPDX-License-Identifier: MIT */
'use strict';

const byId = (id) => document.getElementById(id);
const numberFormat = new Intl.NumberFormat('en', { maximumFractionDigits: 1 });
const fmt = (value) => numberFormat.format(value);
const MAX_POINTS = 16000;
const node = new URLSearchParams(window.location.search).get('node') || 'localhost';
const snapshotUrl = '/api2/json/nodes/' + encodeURIComponent(node) + '/sensors';
let refreshMs = 500;
let fetchTimer = null;
let activeController = null;
let loading = false;
let latestPayload = null;
let latestToken = null;
let latestArrival = null;
let serverAgeMs = 0;
let errorMessage = null;
let cpuId = null;
let sourceSignature = '';
let sampleCount = 0;
let compressed = false;
let sessionStarted = performance.now();
let history = [];
let minimum = Infinity;
let maximum = -Infinity;
let breakNext = false;
let chartFrame = null;

const stateNames = { normal: 'Below thresholds', warning: 'Above max', critical: 'Critical threshold', neutral: 'No thresholds' };

function classify(metric) {
  if (!metric || metric.unit !== '°C') return 'neutral';
  if (Number.isFinite(metric.critical) && metric.value >= metric.critical) return 'critical';
  if (Number.isFinite(metric.max) && metric.value >= metric.max) return 'warning';
  return Number.isFinite(metric.max) || Number.isFinite(metric.critical) ? 'normal' : 'neutral';
}

function validatePayload(payload) {
  if (!payload || typeof payload !== 'object' || !Array.isArray(payload.metrics)
      || payload.metrics.length > 512 || !Number.isFinite(Date.parse(payload.updated_at))
      || typeof payload.session !== 'string' || !/^[a-f0-9]{16}$/.test(payload.session)
      || !Number.isSafeInteger(payload.sequence) || payload.sequence < 1) {
    throw new Error('Invalid sensor snapshot');
  }
  const ids = new Set();
  const metrics = payload.metrics.filter((m) => {
    if (!m || typeof m.id !== 'string' || m.id.length > 80 || ids.has(m.id)
        || typeof m.name !== 'string' || m.name.length > 120
        || !['cpu', 'storage', 'system', 'fans', 'gpu'].includes(m.category)
        || !['°C', 'RPM'].includes(m.unit) || !Number.isFinite(m.value)) return false;
    ids.add(m.id);
    return true;
  });
  if (!metrics.length) throw new Error('No valid sensor readings');
  return { ...payload, metrics };
}

function updateHero(prefix, metric) {
  const state = classify(metric);
  byId(prefix + 'State').className = 'state ' + state;
  byId(prefix + 'State').textContent = metric ? stateNames[state] : 'No data';
  byId(prefix + 'Value').textContent = metric ? `${fmt(metric.value)} °C` : '—';
  byId(prefix + 'Name').textContent = metric ? metric.name : 'Sensor not available';
  const ceiling = metric && (Number.isFinite(metric.critical) ? metric.critical : metric.max);
  byId(prefix + 'Meter').className = 'meter-fill ' + state;
  byId(prefix + 'Meter').style.width = metric && Number.isFinite(ceiling) && ceiling > 0
    ? Math.max(0, Math.min(100, metric.value / ceiling * 100)) + '%' : '0%';
  const limits = [];
  if (metric && Number.isFinite(metric.max)) limits.push(`Max ${fmt(metric.max)} °C`);
  if (metric && Number.isFinite(metric.critical)) limits.push(`Critical ${fmt(metric.critical)} °C`);
  byId(prefix + 'Limits').textContent = limits.join(' · ') || 'No thresholds reported by this sensor';
}

function makeCard(metric) {
  const card = document.createElement('article');
  card.className = 'sensor-card';
  card.dataset.state = classify(metric);
  const title = document.createElement('div');
  title.className = 'sensor-name';
  title.textContent = metric.name;
  const value = document.createElement('div');
  value.className = 'sensor-value';
  value.append(document.createTextNode(fmt(metric.value)));
  const unit = document.createElement('small');
  unit.textContent = metric.unit;
  value.append(unit);
  const note = document.createElement('div');
  note.className = 'sensor-meta';
  note.textContent = metric.unit === 'RPM'
    ? (metric.value === 0 ? 'Zero reported; verify fan telemetry' : 'Reported fan speed')
    : stateNames[classify(metric)];
  card.append(title, value, note);
  return card;
}

function renderGroup(id, metrics) {
  const box = byId(id);
  if (metrics.length) {
    box.replaceChildren(...metrics.map(makeCard));
  } else {
    const empty = document.createElement('p');
    empty.className = 'empty';
    empty.textContent = 'No sensors reported for this group.';
    box.replaceChildren(empty);
  }
}

function pickDefaultCpu(metrics) {
  return metrics.find((m) => /\/ Package$/.test(m.name))
    || metrics.find((m) => /\/ Tdie$/.test(m.name))
    || metrics.find((m) => m.role === 'package') || metrics[0];
}

function resetHistory() {
  history = [];
  sampleCount = 0;
  minimum = Infinity;
  maximum = -Infinity;
  compressed = false;
  sessionStarted = performance.now();
  breakNext = true;
  for (const id of ['chartCurrent', 'chartMin', 'chartMax']) byId(id).textContent = '—';
  byId('chartSamples').textContent = '0';
  byId('historyNote').textContent = 'Reloading or changing the source resets history. Hidden tabs pause polling.';
  requestChart();
}

function updateSources(cpus) {
  const signature = cpus.map((m) => m.id + ':' + m.name).join('|');
  if (signature === sourceSignature) return;
  sourceSignature = signature;
  const previous = cpuId;
  if (!cpus.some((m) => m.id === cpuId)) cpuId = pickDefaultCpu(cpus)?.id || null;
  const select = byId('cpuSource');
  const options = cpus.map((m) => {
    const option = document.createElement('option');
    option.value = m.id;
    option.textContent = m.name;
    return option;
  });
  if (!options.length) {
    const option = document.createElement('option');
    option.value = '';
    option.textContent = 'CPU sensor unavailable';
    options.push(option);
  }
  select.replaceChildren(...options);
  select.value = cpuId || '';
  if (previous !== null && previous !== cpuId) resetHistory();
}

function render(payload, addSample) {
  const metrics = payload.metrics;
  const cpus = metrics.filter((m) => m.category === 'cpu')
    .sort((a, b) => a.name.localeCompare(b.name, 'en', { numeric: true }));
  updateSources(cpus);
  const cpu = cpus.find((m) => m.id === cpuId);
  const storage = metrics.find((m) => m.category === 'storage' && m.role === 'composite')
    || metrics.find((m) => m.category === 'storage');
  updateHero('cpu', cpu);
  updateHero('nvme', storage);
  renderGroup('cores', cpus.filter((m) => m.id !== cpuId));
  renderGroup('other', metrics.filter((m) => m.category !== 'cpu' && m.id !== storage?.id));
  if (addSample && cpu) addChartSample(cpu);
  byId('chartTitle').textContent = cpu ? `${cpu.name} history` : 'CPU temperature history';
}

function addChartSample(metric) {
  const elapsed = performance.now() - sessionStarted;
  const previous = history[history.length - 1];
  history.push({ time: elapsed, value: metric.value,
    gap: breakNext || !!(previous && elapsed - previous.time > Math.max(2500, refreshMs * 5)) });
  breakNext = false;
  sampleCount++;
  minimum = Math.min(minimum, metric.value);
  maximum = Math.max(maximum, metric.value);
  if (history.length > MAX_POINTS) compressHistory();
  byId('chartCurrent').textContent = fmt(metric.value) + ' °C';
  byId('chartMin').textContent = fmt(minimum) + ' °C';
  byId('chartMax').textContent = fmt(maximum) + ' °C';
  byId('chartSamples').textContent = sampleCount.toLocaleString('en');
  requestChart();
}

function compressHistory() {
  // Retain first, minimum, maximum and last per 8-snapshot block. The entire
  // time span and extrema survive; resolution decreases in long-lived tabs.
  const next = [];
  for (let start = 0; start < history.length; start += 8) {
    const block = history.slice(start, start + 8);
    let low = 0, high = 0;
    for (let i = 1; i < block.length; i++) {
      if (block[i].value < block[low].value) low = i;
      if (block[i].value > block[high].value) high = i;
    }
    const chosen = [...new Set([0, low, high, block.length - 1])].sort((a, b) => a - b);
    let previous = -1;
    for (const i of chosen) {
      const gap = block.slice(previous + 1, i + 1).some((p) => p.gap);
      next.push({ ...block[i], gap });
      previous = i;
    }
  }
  history = next;
  compressed = true;
  byId('historyNote').textContent = 'Long session: history is downsampled to bound memory. Time span and temperature extrema are retained.';
}

function duration(ms) {
  const seconds = Math.floor(Math.max(0, ms) / 1000);
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor(seconds / 60) % 60;
  const rest = seconds % 60;
  return (hours ? hours + ':' : '') + String(minutes).padStart(2, '0') + ':' + String(rest).padStart(2, '0');
}

function requestChart() {
  if (chartFrame !== null || document.hidden) return;
  chartFrame = requestAnimationFrame(() => { chartFrame = null; drawChart(); });
}

function displayPoints(width, xMax) {
  if (history.length <= width * 3) return history;
  const points = [];
  let i = 0;
  while (i < history.length) {
    const first = i;
    const column = Math.floor(history[i].time / xMax * width);
    let low = i, high = i;
    while (i < history.length && Math.floor(history[i].time / xMax * width) === column) {
      if (history[i].value < history[low].value) low = i;
      if (history[i].value > history[high].value) high = i;
      i++;
    }
    const chosen = [...new Set([first, low, high, i - 1])].sort((a, b) => a - b);
    let last = first - 1;
    for (const index of chosen) {
      let gap = false;
      for (let k = last + 1; k <= index; k++) gap ||= history[k].gap;
      points.push({ ...history[index], gap });
      last = index;
    }
  }
  return points;
}

function drawChart() {
  const canvas = byId('cpuChart');
  const width = Math.max(1, canvas.clientWidth);
  const height = Math.max(1, canvas.clientHeight);
  const scale = Math.min(window.devicePixelRatio || 1, 2);
  const ctx = canvas.getContext('2d');
  if (!ctx) return;
  if (canvas.width !== Math.round(width * scale) || canvas.height !== Math.round(height * scale)) {
    canvas.width = Math.round(width * scale);
    canvas.height = Math.round(height * scale);
  }
  ctx.setTransform(scale, 0, 0, scale, 0, 0);
  ctx.clearRect(0, 0, width, height);
  const css = getComputedStyle(document.documentElement);
  const grid = css.getPropertyValue('--chart-grid').trim();
  const text = css.getPropertyValue('--chart-text').trim();
  const line = css.getPropertyValue('--chart-line').trim();
  const left = width < 450 ? 37 : 48, right = 14, top = 18, bottom = 32;
  const plotWidth = Math.max(1, width - left - right);
  const plotHeight = Math.max(1, height - top - bottom);
  const xMax = Math.max(4000, performance.now() - sessionStarted);
  const min = history.length ? minimum : 35, max = history.length ? maximum : 50;
  const yMin = Math.floor((min - 3) / 5) * 5;
  const yMax = Math.max(yMin + 10, Math.ceil((max + 3) / 5) * 5);
  const px = (t) => left + Math.max(0, Math.min(xMax, t)) / xMax * plotWidth;
  const py = (v) => top + (yMax - v) / (yMax - yMin) * plotHeight;
  ctx.font = '11px system-ui, sans-serif';
  ctx.textBaseline = 'middle';
  ctx.lineWidth = 1;
  for (let i = 0; i <= 4; i++) {
    const y = top + i * plotHeight / 4;
    ctx.strokeStyle = grid;
    ctx.beginPath(); ctx.moveTo(left, y); ctx.lineTo(left + plotWidth, y); ctx.stroke();
    ctx.textAlign = 'right'; ctx.fillStyle = text;
    ctx.fillText(fmt(yMax - i * (yMax - yMin) / 4) + '°', left - 8, y);
  }
  const ticks = width < 450 ? 3 : 5;
  for (let i = 0; i <= ticks; i++) {
    ctx.textAlign = i === 0 ? 'left' : i === ticks ? 'right' : 'center';
    ctx.fillStyle = text;
    ctx.fillText(duration(xMax * i / ticks), left + plotWidth * i / ticks, height - 12);
  }
  if (!history.length) {
    ctx.textAlign = 'center'; ctx.fillStyle = text;
    ctx.fillText('Waiting for CPU temperature samples', left + plotWidth / 2, top + plotHeight / 2);
  } else {
    const points = displayPoints(Math.floor(plotWidth), xMax);
    ctx.save(); ctx.beginPath(); ctx.rect(left, top, plotWidth, plotHeight); ctx.clip();
    ctx.strokeStyle = line; ctx.lineWidth = 2; ctx.lineJoin = 'round';
    ctx.beginPath();
    points.forEach((p, i) => {
      if (i === 0 || p.gap) ctx.moveTo(px(p.time), py(p.value));
      else ctx.lineTo(px(p.time), py(p.value));
    });
    ctx.stroke();
    const last = points[points.length - 1];
    ctx.fillStyle = line; ctx.beginPath(); ctx.arc(px(last.time), py(last.value), 3.5, 0, Math.PI * 2); ctx.fill();
    ctx.restore();
  }
  byId('chartDuration').textContent = duration(xMax === 4000 && !history.length ? 0 : performance.now() - sessionStarted);
}

function updateConnection() {
  const badge = byId('connection');
  const stale = latestArrival !== null &&
    (performance.now() - latestArrival + serverAgeMs > Math.max(3000, refreshMs * 4));
  document.body.classList.toggle('data-stale', !!errorMessage || stale);
  if (document.hidden) {
    badge.className = 'connection pending'; badge.textContent = 'Paused in background';
  } else if (errorMessage) {
    badge.className = 'connection danger'; badge.textContent = 'Connection error';
    byId('updated').textContent = errorMessage;
  } else if (stale) {
    badge.className = 'connection warning'; badge.textContent = 'Snapshot is stale';
  } else if (latestArrival !== null) {
    badge.className = 'connection ok'; badge.textContent = 'Live readings';
  }
  if (!errorMessage && latestPayload) {
    const time = new Date(latestPayload.updated_at).toLocaleTimeString('en', { hour12: false });
    byId('updated').textContent = `Sampled ${time} · ${Math.round(refreshMs)} ms target`;
  }
}

async function refresh() {
  if (loading || document.hidden) return;
  loading = true;
  const started = performance.now();
  const controller = new AbortController();
  activeController = controller;
  const timeout = setTimeout(() => controller.abort(), 4000);
  try {
    const response = await fetch(snapshotUrl, {
      cache: 'no-store', credentials: 'same-origin', referrerPolicy: 'no-referrer', signal: controller.signal,
    });
    if (response.status === 401 || response.status === 403) {
      const error = new Error(response.status === 401
        ? 'Log in to Proxmox on this origin, then reload this page'
        : 'Sys.Audit permission is required on this node');
      error.name = 'AccessError';
      throw error;
    }
    if (!response.ok) throw new Error('HTTP ' + response.status);
    const raw = await response.text();
    if (raw.length > 262144) throw new Error('Sensor snapshot is too large');
    const payload = validatePayload(JSON.parse(raw).data);
    const interval = Number(payload.sample_interval_ms);
    refreshMs = Number.isFinite(interval) && interval >= 100 && interval <= 60000 ? interval : 500;
    byId('sampling').textContent = `${Math.round(refreshMs)} ms target interval`;
    const token = payload.session + ':' + payload.sequence;
    if (token !== latestToken) {
      const restarted = latestPayload && latestPayload.session !== payload.session;
      if (restarted) breakNext = true;
      // Compare two server times, not the browser clock. HTTP Date is optional.
      const serverDate = Date.parse(response.headers.get('Date'));
      serverAgeMs = Number.isFinite(serverDate) ? Math.max(0, serverDate - Date.parse(payload.updated_at)) : 0;
      latestArrival = performance.now();
      latestToken = token;
      latestPayload = payload;
      const isFresh = serverAgeMs <= Math.max(3000, refreshMs * 4);
      render(payload, isFresh);
      if (!isFresh) breakNext = true;
    }
    errorMessage = null;
  } catch (error) {
    if (!document.hidden) errorMessage = error.name === 'AccessError' ? error.message
      : error.name === 'AbortError' ? 'Request timed out' : 'Cannot read the sensor snapshot';
    breakNext = true;
  } finally {
    clearTimeout(timeout);
    activeController = null;
    loading = false;
    updateConnection();
    requestChart();
    if (!document.hidden) {
      const delay = errorMessage ? Math.max(2000, refreshMs) : Math.max(50, refreshMs - (performance.now() - started));
      fetchTimer = setTimeout(refresh, delay);
    }
  }
}

byId('cpuSource').addEventListener('change', (event) => {
  cpuId = event.target.value || null;
  resetHistory();
  const fresh = latestArrival !== null && !errorMessage &&
    performance.now() - latestArrival + serverAgeMs <= Math.max(3000, refreshMs * 4);
  if (latestPayload) render(latestPayload, fresh);
});
document.addEventListener('visibilitychange', () => {
  clearTimeout(fetchTimer);
  if (document.hidden) { activeController?.abort(); breakNext = true; }
  else if (!loading) refresh();
  updateConnection();
});
window.addEventListener('resize', requestChart);
window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', requestChart);
window.addEventListener('pagehide', () => { clearTimeout(fetchTimer); activeController?.abort(); });
setInterval(() => { if (!document.hidden) { updateConnection(); requestChart(); } }, 1000);
requestChart();
refresh();
PVE_SENSORS_EMBEDDED_FILE_8_END
}

if [[ "$MODE" == extract ]]; then
  [[ ! -e "$EXTRACT_DIR" && ! -L "$EXTRACT_DIR" ]] || die 'Extraction target must not exist.'
  mkdir -m 0755 -- "$EXTRACT_DIR"
  write_payload "$EXTRACT_DIR"
  say "Embedded sources extracted to: $EXTRACT_DIR"
  exit 0
fi

if [[ "$MODE" == status ]]; then
  command -v systemctl >/dev/null || die 'systemctl is required.'
  systemctl status "$SERVICE" --no-pager
  exit $?
fi

[[ "$EUID" -eq 0 ]] || die 'Run as root on the Proxmox VE host, not in a VM or container.'
for cmd in systemctl dpkg-query install mktemp cp mv rm mkdir flock perl; do
  command -v "$cmd" >/dev/null || die "Required base utility is missing: $cmd"
done
[[ -d /run/systemd/system ]] || die 'A booted systemd host is required.'
[[ "$(dpkg-query -W -f='${Status}' pve-manager 2>/dev/null || true)" == 'install ok installed' ]] \
  || die 'pve-manager is not installed. Run on the Proxmox VE host.'
[[ -d "$WEB" && ! -L "$WEB" ]] || die 'The expected PVE static asset directory is unavailable.'
[[ -x /usr/bin/python3 ]] || die 'Python 3 is missing. Restore the PVE base system before installing.'
/usr/bin/python3 -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' \
  || die 'Python 3.9 or newer is required.'

# Serialise this project's installers. The file contains no host identity.
[[ ! -L /run/pve-sensors-installer ]] || die 'Installer lock directory is a symlink.'
install -d -m 0700 /run/pve-sensors-installer
[[ ! -L /run/pve-sensors-installer/lock ]] || die 'Installer lock file is a symlink.'
exec 9>/run/pve-sensors-installer/lock
flock -n 9 || die 'Another PVE Sensors Live installer is running.'

confirm() {
  [[ "$ASSUME_YES" == yes ]] && return 0
  [[ -t 0 ]] || die 'Interactive confirmation is required; use --yes for reviewed automation.'
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" == y || "$answer" == Y ]] || die 'Cancelled.'
}

backup_files() {
  install -d -m 0700 /var/backups/pve-sensors
  BACKUP=$(mktemp -d /var/backups/pve-sensors/backup.XXXXXXXX)
  for file in "${FILES[@]}" "$NODES"; do
    if [[ -e "$file" || -L "$file" ]]; then
      [[ ! -d "$file" ]] || die "Refusing to replace a directory: $file"
      mkdir -p -- "$BACKUP/$(dirname "${file#/}")"
      cp -a -- "$file" "$BACKUP/${file#/}"
    fi
  done
  systemctl is-active --quiet "$SERVICE" && OLD_ACTIVE=yes || true
  systemctl is-enabled --quiet "$SERVICE" && OLD_ENABLED=yes || true
  printf 'active=%s\nenabled=%s\n' "$OLD_ACTIVE" "$OLD_ENABLED" > "$BACKUP/service-state.txt"
  printf '%s\n' "${FILES[@]}" "$NODES" > "$BACKUP/managed-files.txt"
}

cleanup() {
  local result=$? restore_failed=no
  trap - EXIT INT TERM
  if [[ "$CHANGED" == yes && "$COMMITTED" != yes ]]; then
    say 'Installation did not finish. Attempting to restore project files and service state.' >&2
    systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
    for file in "${FILES[@]}" "$NODES"; do
      rm -f -- "$file" || restore_failed=yes
      if [[ -e "$BACKUP/${file#/}" || -L "$BACKUP/${file#/}" ]]; then
        cp -a -- "$BACKUP/${file#/}" "$file" || restore_failed=yes
      fi
    done
    # Never restore the old public snapshot, even when reverting a v1 upgrade.
    rm -f -- "$WEB/pve-sensors.json" || restore_failed=yes
    systemctl reload pvedaemon pveproxy || restore_failed=yes
    systemctl daemon-reload || restore_failed=yes
    if [[ "$OLD_ENABLED" == yes ]]; then systemctl enable "$SERVICE" >/dev/null 2>&1 || restore_failed=yes; fi
    if [[ "$OLD_ACTIVE" == yes ]]; then systemctl start "$SERVICE" || restore_failed=yes; fi
    say "Project backup: $BACKUP" >&2
    if [[ "$restore_failed" == yes ]]; then
      say 'WARNING: automatic restoration was incomplete. Inspect the backup and service manually.' >&2
    fi
    say 'APT package changes, if any, are not rolled back.' >&2
    [[ "$result" -ne 0 ]] || result=1
  fi
  if [[ -n "$STAGE" && -d "$STAGE" ]]; then rm -rf -- "$STAGE"; fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

STAGE=$(mktemp -d /tmp/pve-sensors-install.XXXXXXXX)
chmod 0700 "$STAGE"
write_payload "$STAGE"

put_file() {
  local source="$1" destination="$2" mode="$3" temporary
  temporary=$(mktemp "$(dirname "$destination")/.pve-sensors-install.XXXXXXXX")
  install -m "$mode" -- "$source" "$temporary"
  mv -fT -- "$temporary" "$destination"
}

if [[ "$MODE" == uninstall ]]; then
  [[ -f "$MARKER" && ! -L "$MARKER" ]] || die 'No installation marker found; refusing to remove unowned files.'
  confirm 'Uninstall PVE Sensors Live and reload the Proxmox API services?'
  rm -f -- "$WEB/pve-sensors.json"
  /usr/bin/python3 -I "$STAGE/patch_nodes.py" "$NODES" "$STAGE/Nodes.pm" --remove
  backup_files
  CHANGED=yes
  systemctl disable --now "$SERVICE"
  put_file "$STAGE/Nodes.pm" "$NODES" 0644
  for file in "${FILES[@]}"; do rm -f -- "$file"; done
  systemctl reload pvedaemon pveproxy
  systemctl daemon-reload
  systemctl reset-failed "$SERVICE" 2>/dev/null || true
  COMMITTED=yes
  say "Uninstalled. Backup retained at: $BACKUP"
  say 'Guests stay running. APT packages were not removed.'
  exit 0
fi

say 'Sensor data requires a Proxmox session and Sys.Audit on the requested node.'
say 'The installer patches Nodes.pm and reloads pvedaemon/pveproxy; guests stay running.'
confirm 'Install the authenticated Sensors API?'
# Revocation is intentionally outside rollback and precedes compatibility checks.
rm -f -- "$WEB/pve-sensors.json"
[[ -f "$NODES" && ! -L "$NODES" ]] || die 'Expected a regular Proxmox Nodes.pm.'
/usr/bin/python3 -I "$STAGE/patch_nodes.py" "$NODES" "$STAGE/Nodes.pm"

if [[ ! -e "$MARKER" ]]; then
  for file in "${FILES[@]}"; do
    [[ ! -e "$file" && ! -L "$file" ]] || die "Unmanaged file already exists: $file"
  done
else
  [[ -f "$MARKER" && ! -L "$MARKER" ]] || die 'Invalid installation marker.'
fi
for file in "${FILES[@]}"; do
  [[ ! -d "$file" ]] || die "Refusing to replace a directory: $file"
  if [[ -L "$file" ]]; then
    die "Unexpected symlink in a managed file: $file"
  fi
done
[[ "$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)" != masked ]] || die 'The service is masked; review and unmask it explicitly first.'

/usr/bin/python3 -I -B - "$STAGE/pve-sensors-agent.py" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
compile(path.read_bytes(), str(path), "exec")
PY

# Read an existing interval as data, not executable shell code.
if [[ -z "$INTERVAL" ]]; then
  INTERVAL=$(/usr/bin/python3 -I - "$CONFIG" <<'PY'
import pathlib, re, sys
value = "0.5"
path = pathlib.Path(sys.argv[1])
if path.is_file():
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"\s*PVE_SENSORS_INTERVAL=([0-9]+(?:\.[0-9]+)?)\s*", line)
        if match:
            value = match.group(1)
print(value)
PY
)
fi
INTERVAL=$(/usr/bin/python3 -I - "$INTERVAL" <<'PY'
import math, sys
try:
    value = float(sys.argv[1])
    assert math.isfinite(value) and 0.1 <= value <= 60
except (ValueError, AssertionError):
    sys.exit("Interval must be a finite number between 0.1 and 60 seconds.")
print(format(value, ".6g"))
PY
)
if [[ "$INTERVAL" == 0.1 ]]; then
  say 'WARNING: 100 ms polling is experimental. Check collection time, CPU and HTTP logging overhead.'
fi

# Package manager trust stays with the host's configured signed repositories.
# Never use apt-get -f, an upgrade, an autoremove, or an external package source.
if [[ ! -x /usr/bin/sensors ]]; then
  command -v apt-get >/dev/null || die 'apt-get is unavailable.'
  say 'lm-sensors is missing. Refreshing your existing APT package indexes.'
  apt-get update
  apt-get --simulate --no-remove --no-install-recommends install lm-sensors
  confirm 'Install lm-sensors and its required library dependencies from existing repositories?'
  apt-get install --yes --no-remove --no-install-recommends lm-sensors
fi
[[ -x /usr/bin/sensors ]] || die 'sensors was not installed successfully.'
RUNUSER=$(command -v runuser) || die 'runuser is missing from the Debian base system.'
command -v timeout >/dev/null || die 'timeout is missing from the Debian base system.'

# Test read-only hwmon access as an existing unprivileged account. The actual
# service receives its own isolated dynamic UID, not the shared nobody UID.
"$RUNUSER" -u nobody -- timeout 5 /usr/bin/sensors -j \
  | /usr/bin/python3 -I -B "$STAGE/pve-sensors-agent.py" --validate-stdin

backup_files
CHANGED=yes
if [[ "$OLD_ACTIVE" == yes ]]; then systemctl stop "$SERVICE"; fi
install -d -m 0755 /usr/local/libexec /usr/local/share/pve-sensors

put_file "$STAGE/pve-sensors-agent.py" "$AGENT" 0755
put_file "$STAGE/pve-sensors.service" "$UNIT" 0644
for extension in html css js; do
  put_file "$STAGE/pve-sensors.$extension" "$WEB/pve-sensors.$extension" 0644
done
# Preserve administrator comments/settings; only update the supported interval.
/usr/bin/python3 -I - "$CONFIG" "$STAGE/pve-sensors.defaults" "$INTERVAL" "$STAGE/new-config" <<'PY'
import pathlib, re, sys
existing, default, value, destination = sys.argv[1:]
path = pathlib.Path(existing)
text = (path if path.is_file() else pathlib.Path(default)).read_text(encoding="utf-8")
lines = [line for line in text.splitlines() if not re.match(r"\s*PVE_SENSORS_INTERVAL\s*=", line)]
lines.append("PVE_SENSORS_INTERVAL=" + value)
pathlib.Path(destination).write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
put_file "$STAGE/new-config" "$CONFIG" 0644
put_file "$STAGE/PveSensors.pm" "$API" 0644
# Compile the staged registration against the installed PVE modules before use.
perl -T -c "$STAGE/Nodes.pm"
put_file "$STAGE/Nodes.pm" "$NODES" 0644
systemctl reload pvedaemon pveproxy
printf '%s\n' "$VERSION" > "$STAGE/version"
put_file "$STAGE/version" "$MARKER" 0644
systemctl daemon-reload
systemctl enable --now "$SERVICE"

/usr/bin/python3 -I - "$RUNTIME" <<'PY'
import json, pathlib, sys, time
path = pathlib.Path(sys.argv[1])
for _ in range(40):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if data.get("metrics") and time.time() - path.stat().st_mtime < 5:
            break
    except (OSError, ValueError):
        pass
    time.sleep(0.25)
else:
    sys.exit("Collector did not produce a fresh snapshot. Inspect journalctl -u pve-sensors.service.")
PY
systemctl is-active --quiet "$SERVICE" || die 'The collector is not running.'
"$RUNUSER" -u www-data -- /usr/bin/python3 -I -c \
  'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); assert d["metrics"]' "$RUNTIME"

if [[ "$SKIP_HTTP" != yes ]]; then
  # Loopback only: PVE often uses a locally signed certificate. This probe
  # deliberately skips certificate verification; browser TLS is not changed.
  /usr/bin/python3 -I - "$WEB" <<'PY'
import pathlib, ssl, sys, time, urllib.error, urllib.request
root = pathlib.Path(sys.argv[1])
context = ssl._create_unverified_context()
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        return None

opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(),
                                    urllib.request.HTTPSHandler(context=context))
for name in ("pve-sensors.html", "pve-sensors.css", "pve-sensors.js"):
    url = "https://127.0.0.1:8006/pve2/js/" + name + "?probe=" + str(time.time_ns())
    try:
        with opener.open(url, timeout=5) as response:
            if response.geturl().split("?", 1)[0] != url.split("?", 1)[0]:
                raise ValueError("Unexpected redirect")
            body = response.read(1048576)
            assert body == (root / name).read_bytes()
    except Exception as exc:
        sys.exit("HTTPS loopback verification failed (" + type(exc).__name__ +
                 "). For a restricted listener, review --skip-http-check in README.md.")
for path, expected in (("/pve2/js/pve-sensors.json", 404),
                       ("/api2/json/nodes/localhost/sensors", 401)):
    try:
        opener.open("https://127.0.0.1:8006" + path, timeout=5).close()
    except urllib.error.HTTPError as exc:
        if exc.code != expected:
            sys.exit(f"Unexpected HTTP {exc.code} for {path}; expected {expected}")
    else:
        sys.exit(f"Unauthenticated access unexpectedly succeeded: {path}")
print("Local HTTPS checks passed: public snapshot absent; API requires authentication.")
PY
else
  say 'WARNING: HTTPS serving was not tested. Verify the dashboard from your management browser.'
fi

COMMITTED=yes
say ''
say "PVE Sensors Live $VERSION installed."
say "Collector interval: $INTERVAL seconds"
say "Current snapshot: $RUNTIME (normally tmpfs)"
say "Open /pve2/js/pve-sensors.html on this node's existing HTTPS :8006 origin."
say 'Service: systemctl status pve-sensors.service --no-pager'
say "Project backup: $BACKUP"
say 'Proxmox API services were reloaded. Guests were not restarted.'
say 'Log in to Proxmox on the same origin before opening the dashboard.'
