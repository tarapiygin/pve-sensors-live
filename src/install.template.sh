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
@@EMBEDDED_PAYLOAD@@
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

# The public path must stay absent even when HTTPS checks are skipped.
[[ ! -e "$WEB/pve-sensors.json" && ! -L "$WEB/pve-sensors.json" ]] \
  || die 'The public sensor JSON path still exists.'

if [[ "$SKIP_HTTP" != yes ]]; then
  # Loopback only: PVE often uses a locally signed certificate. This probe
  # deliberately skips certificate verification; browser TLS is not changed.
  /usr/bin/python3 -I - "$WEB" <<'PY'
import json, pathlib, ssl, sys, time, urllib.error, urllib.request
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
# PVE's static-file handler can report a missing file as 500, not 404.
# Keep the API authentication check strict and reject exposed measurements.
for path, expected in (("/pve2/js/pve-sensors.json", (404, 500)),
                       ("/api2/json/nodes/localhost/sensors", (401,))):
    try:
        opener.open("https://127.0.0.1:8006" + path, timeout=5).close()
    except urllib.error.HTTPError as exc:
        with exc:
            body = exc.read(1048577)
        if exc.code not in expected:
            sys.exit(f"Unexpected HTTP {exc.code} for {path}; expected {expected}")
        if len(body) > 1048576:
            sys.exit(f"Unexpected oversized error response for {path}")
        try:
            payload = json.loads(body)
        except (ValueError, UnicodeError):
            payload = None
        if isinstance(payload, dict) and (
            "metrics" in payload or
            isinstance(payload.get("data"), dict) and "metrics" in payload["data"]
        ):
            sys.exit(f"Unauthenticated response contains sensor metrics: {path}")
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
