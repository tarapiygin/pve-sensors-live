# PVE Sensors Live

**Live hardware temperatures in your existing Proxmox VE web server. No extra dashboard stack.**

PVE Sensors Live adds **Node → Sensors** to the existing Proxmox VE interface. A read-only Python collector polls `lm-sensors` and writes one JSON snapshot under `/run`. A small ExtJS panel reads it through the authenticated Proxmox API and displays the existing temperature cards and CPU chart. Chart history starts when the view opens and stays only in browser memory.

**One additional APT package when needed: `lm-sensors`.** Python's standard library, systemd and Debian base utilities come from the host. There is no pip, npm, CDN, database, container, exporter stack, charting library, extra web server or new listening port.

> **Sensor readings require a Proxmox session and `Sys.Audit` on the requested node.** Only the project JavaScript and CSS remain public assets; measurements are available only through `GET /api2/json/nodes/{node}/sensors`. Installation removes the obsolete standalone HTML page and public JSON link, adds small API/UI hooks, and reloads `pvedaemon`/`pveproxy`. Keep the management interface on a trusted network.

The screenshots below show the existing cards and chart before native-tab integration.

![Dark desktop dashboard with a CPU history chart](docs/screenshots/desktop-dark.png)

<details>
<summary>Light theme and mobile screenshots</summary>

![Light desktop dashboard](docs/screenshots/desktop-light.png)

<img src="docs/screenshots/mobile-light.png" alt="Mobile dashboard with synthetic temperature readings" width="340">

</details>

## What it does

- Displays available CPU, storage, system, GPU temperature and fan-speed readings from `sensors -j`.
- Targets a **500 ms** polling interval by default, configurable between 100 ms and 60 seconds.
- Plots a selectable CPU sensor with session minimum, maximum, elapsed time and unique snapshot count.
- Recognizes familiar Intel CPU, AMD CPU, NVMe, drive, Wi-Fi and ACPI drivers. Other temperature channels receive generic labels.
- Uses sensor-reported temperature thresholds when present. Missing thresholds are not treated as proof of safety, and zero RPM is not automatically treated as a failed fan.
- Flags stale snapshots, skips duplicate samples, handles reconnects and pauses browser polling while the tab is hidden.
- Keeps bounded chart memory by downsampling long sessions while retaining the overall time span and extrema.

It does **not** control fans, configure sensors, run automatic hardware probing, provide alert delivery, store historical measurements on the server.

## Requirements and compatibility

The intended target is a **Proxmox VE 9.x host** with systemd and Python 3.9 or newer. Run the installer on the physical node, not in a guest VM or LXC container. The static asset directory must be `/usr/share/pve-manager/js`, and `sensors -j` must expose at least one valid temperature or fan measurement to an unprivileged account.

| Component | Where it comes from |
| --- | --- |
| `lm-sensors` and its required libraries | Installed from the host's existing APT repositories if `/usr/bin/sensors` is missing |
| Python 3.9+ | Existing host runtime; standard library only |
| systemd, Bash, `runuser`, `timeout`, `flock`, core utilities | Existing Proxmox/Debian base system |
| HTTPS and authentication | Existing `pveproxy`, Proxmox Perl API modules and session/ACL checks |
| Widget JavaScript/CSS, Python collector, Perl API module, unit file | Embedded in `install.sh`; also available as readable source files |

The installer checks the base system instead of repairing or upgrading a damaged Proxmox installation. It does not modify repositories or disable certificate validation for package downloads. If APT has unrelated repository errors, resolve them separately.

The API registration, node-tab registration and script include are small local patches, **not a supported Proxmox extension API**. After a `pve-manager` update, re-run the installer to reapply them. An incompatible layout stops installation; an overwritten patch makes the endpoint unavailable. Neither case exposes the JSON publicly. No automatic update hook is installed. See [validation notes](docs/VALIDATION.md) for the tests performed and the remaining live-host checks.

## Install

Run this command in an interactive **root shell on the Proxmox VE host** (not inside a VM or container):

```bash
curl -fsSL https://github.com/tarapiygin/pve-sensors-live/releases/latest/download/install.sh -o install.sh && bash install.sh
```

Confirm the installer prompts. No repository clone or local build is needed. After installation, hard-refresh the Proxmox web interface and open **Node → Sensors**.

The download link becomes available after the first release is published. For unreleased code, use the [installer from main](https://raw.githubusercontent.com/tarapiygin/pve-sensors-live/main/install.sh).

To install from a local copy instead, copy the project to the Proxmox host, change into its directory, inspect the installer and run:

```bash
sha256sum -c SHA256SUMS
less install.sh
bash install.sh
```

`install.sh` is self-contained. Copying **only that file** is sufficient for installation; the rest of the repository is for review, documentation and development. When using the single file, compare its checksum with the release manifest before running it. A checksum detects file changes; it is not an independent signature of the publisher.

For a reviewed unattended installation:

```bash
bash install.sh --yes --interval 0.5
```

The installer will:

1. Verify that it is running as root on a Proxmox host, and validate its embedded Python source.
2. Install `lm-sensors` only when needed, using your existing APT repositories, `--no-install-recommends` and `--no-remove`. It displays a simulated package plan before asking for confirmation, unless `--yes` was supplied.
3. Check sensor access with the existing `nobody` account. The actual collector uses a separate systemd dynamic identity, not this shared account.
4. Remove the former public JSON link and standalone HTML page, then check all API/UI patch anchors before modifying Proxmox files; back up affected project files, the three patched Proxmox files and collector service state under `/var/backups/pve-sensors/`.
5. Install the collector, its systemd unit, web assets and `PveSensors.pm`; syntax-check the staged `Nodes.pm`, apply the marked API/UI registrations and script include, then reload the Proxmox API services.
6. Start the collector, wait for a fresh snapshot, verify local `www-data` read access, and check that HTTPS denies an anonymous API request (401) and the old static JSON URL (404 or 500 without measurements). Both obsolete public paths must be absent, including with `--skip-http-check`.

Only the collector is stopped and started during upgrade. `pvedaemon` and `pveproxy` are reloaded to load the API registration; VMs and containers stay running. The only stock JavaScript change registers the Sensors tab; its widget and chart code live in project-owned files. Existing unrelated collectors are not stopped automatically.

### Open Sensors

After installation, hard-refresh the Proxmox interface, sign in and select **a node → Sensors**. The tab uses that selected node automatically, including for node-scoped `Sys.Audit` permissions. No hostname, IP address, password or token is embedded in the project or URL.

The panel pauses requests when hidden, aborts an in-flight request when closing, and releases its timers and event listeners when destroyed. Proxmox destroys inactive node views, so leaving and reopening Sensors starts a fresh chart. A 401 or 403 displays a session or permission error; readings never fall back to a static file.

For clusters, install the extension on every node where you open the UI or collect readings. The API uses Proxmox's normal forwarding to the selected node; it does not aggregate measurements.

### Restricted listeners

By default, installation verifies `https://127.0.0.1:8006`. For this **local verification only**, the probe accepts the node's self-signed certificate. It does not change the node's TLS configuration or the browser's certificate validation.

If `pveproxy` is intentionally bound to a management address rather than loopback, inspect that setup and use:

```bash
bash install.sh --skip-http-check
```

This skips the HTTPS probe only. Filesystem permissions, collector startup and fresh JSON checks still run. Verify Node → Sensors from your management browser afterward.

## Architecture

```mermaid
flowchart TD
    C[Unprivileged collector] -->|atomic write| J[Snapshot in /run]
    B[Browser session] --> A[Proxmox authentication and Sys.Audit]
    A --> R[Read-only Sensors API]
    J --> R
    R --> B
```

The collector is a single long-lived process. Each interval launches one bounded `sensors -j` read, extracts allowlisted fields, and atomically replaces the snapshot. It never starts a web server. Browser reads are handled by the web server already running on the host.

| Path | Purpose |
| --- | --- |
| `/usr/local/libexec/pve-sensors-agent.py` | Collector |
| `/etc/systemd/system/pve-sensors.service` | Hardened service definition |
| `/etc/default/pve-sensors` | Polling interval |
| `/run/pve-sensors/metrics.json` | Current snapshot; recreated after reboot |
| `/usr/share/perl5/PVE/API2/PveSensors.pm` | Read-only authenticated snapshot endpoint |
| `/usr/share/perl5/PVE/API2/Nodes.pm` | One marked Sensors route registration |
| `/usr/share/pve-manager/js/pvemanagerlib.js` | Marked node-tab registration |
| `/usr/share/pve-manager/index.html.tpl` | Marked include for the project widget script |
| `/usr/share/pve-manager/js/pve-sensors.css` | Local styling |
| `/usr/share/pve-manager/js/pve-sensors.js` | Local rendering and chart code |
| `/usr/local/share/pve-sensors/installed-version` | Ownership/version marker for upgrades and removal |
| `/var/backups/pve-sensors/` | Root-readable installation backups |

`/run` is normally tmpfs. There is no project-managed disk history or per-sample write to the web asset directory. This is **not** a claim of zero disk I/O: tmpfs may be swapped depending on host settings, service failures may enter the journal, and `pveproxy` can write an access-log entry for each browser request. The project does not disable or alter Proxmox logging.

## Sampling and chart behavior

The default 0.5-second interval is a target, not a real-time guarantee. Sensor drivers may refresh less frequently, collection may take longer, and browsers can throttle background work. Two different snapshots can legitimately contain identical temperatures.

Only one read is in flight in the collector. If a read exceeds its interval, the agent skips missed deadlines instead of generating a burst. A read is bounded by a two-second subprocess timeout. Successful operation is not logged once per sample; repeated failures are rate-limited in the collector's own messages.

Browser requests do not overlap. The UI follows the interval advertised in the snapshot and backs off after a request failure. It detects unchanged snapshots with a per-process random session identifier and a sequence number, so sub-second samples are not confused by second-resolution file timestamps. The session identifier is not a host identifier or credential.

The chart records **snapshots observed by that tab**, not every server measurement. It cannot reconstruct observations missed during a network interruption or while the tab was hidden. Gaps are left visible. Reloading the page or selecting another CPU sensor starts a new history. When more than 16,000 points accumulate, older detail is compacted while retaining the whole time span and temperature extrema. There is no localStorage, IndexedDB, project-created cookie, browser-to-server history upload or server database. The browser sends the existing Proxmox session cookie to the same-origin API.

### Change the interval

Re-run the installer with an explicit value:

```bash
bash install.sh --interval 1
```

Or edit `/etc/default/pve-sensors` and restart only the collector:

```bash
editor /etc/default/pve-sensors
systemctl restart pve-sensors.service
```

The setting is `PVE_SENSORS_INTERVAL=0.5`. Without an explicit `--interval`, an upgrade preserves a valid existing setting.

100 ms is permitted but **experimental**, not the recommended default. It can create ten sensor reads and approximately ten HTTP requests per second per visible tab. Faster polling does not increase a hardware sensor's native refresh rate. Measure the actual effect on your host rather than assuming negligible overhead.

### Check resource use

```bash
systemctl show pve-sensors.service -p MemoryCurrent -p CPUUsageNSec -p TasksCurrent
journalctl -u pve-sensors.service -n 30 --no-pager
```

`CPUUsageNSec` is cumulative CPU time, not an instantaneous percentage. To estimate the collector's average use of one logical CPU over ten seconds:

```bash
python3 - <<'PY'
import subprocess
import time

def cpu_ns():
    return int(subprocess.check_output([
        'systemctl', 'show', 'pve-sensors.service',
        '--property=CPUUsageNSec', '--value'
    ], text=True).strip())

before = cpu_ns()
started = time.monotonic()
time.sleep(10)
after = cpu_ns()
elapsed = time.monotonic() - started
if after < before:
    raise SystemExit('The service restarted during the measurement; repeat it.')
print(f'Average collector CPU: {(after - before) / 1e9 / elapsed * 100:.2f}% of one logical CPU')
PY
```

That measurement does not include the additional work performed by `pveproxy` or the browser. No universal CPU or memory benchmark is promised.

## Security and privacy

The service uses `DynamicUser=yes`, an empty capability set, a read-only system view, private devices and temporary files, and its own network namespace. It has no TCP/UDP socket access. It can write its runtime directory, but cannot modify the installed web files. Sensor reads use a fixed subprocess argument list, not a shell command built from input.

The snapshot contains temperature and fan values, sanitized category/role labels, thresholds, timestamps, collection timing and an ephemeral sequence identity. Raw sensor labels, bus addresses, serial numbers, usernames, hostname, IP addresses, CPU model names, DMI data and Proxmox credentials are not exported. Unknown inputs receive generated names. This reduces identifying information but does not make telemetry anonymous: sensor counts and changing temperatures can still reveal hardware characteristics and workload activity.

The native panel uses local assets, Shadow DOM for style isolation, `textContent` for sensor names, the existing Proxmox session for same-origin API requests, and no analytics. It does not fetch scripts, fonts or charts from an external service. It is still JavaScript served from the Proxmox management origin, so review it as trusted code before installation.

No `sensors-detect`, `sensors -s`, `i2cdetect`, module loading, GPU capability changes, firewall changes or automatic updates are performed. No API token or root password is needed after installation.

More detail: [SECURITY.md](SECURITY.md). Scope of the publication audit: [privacy review](docs/PRIVACY_REVIEW.md).

## Upgrade, remove and recover

To upgrade, review a new copy of `install.sh` and run `bash install.sh`. The former `--accept-public-data` option is removed. The installer preserves the polling interval and backs up affected files before replacing them. Upgrades from v1 and the API-only v2 remove both `pve-sensors.html` and `pve-sensors.json`; the old bookmark no longer opens a dashboard. There is no background updater or post-APT patch hook.

To remove:

```bash
bash install.sh --uninstall
```

Uninstallation stops and disables `pve-sensors.service`, removes project files and only the marked API/UI hooks in the current `Nodes.pm`, `pvemanagerlib.js` and `index.html.tpl`, and reloads the Proxmox API services and systemd unit definitions. It preserves unrelated upstream changes and leaves `lm-sensors` and backup directories installed.

If installation fails after project files have changed, the installer attempts to restore the previous project files and active/enabled service state. **Rollback is best-effort, not transactional.** APT changes are not undone. Neither the public JSON link nor the obsolete HTML page is restored, including when reverting an upgrade from v1. Read the reported backup path and inspect the service state after an error. Do not manually restore a v1 public JSON link.

To stop polling without removing anything:

```bash
systemctl disable --now pve-sensors.service
```

## Troubleshooting

**No sensor data.** Run `sensors -j` on the host. Hardware support depends on loaded kernel drivers and firmware. The installer intentionally does not probe buses or load modules automatically. Decide whether additional hardware-specific configuration is appropriate before changing the host.

**CPU chart is unavailable, but other cards work.** A known CPU driver may not be exposed. Other valid channels are still shown with generic labels. Extend the classification rules and synthetic tests for additional hardware; do not guess that an arbitrary motherboard channel is the CPU.

**Stale or unreachable snapshot.** Check `systemctl status pve-sensors.service --no-pager`, `journalctl -u pve-sensors.service -n 30 --no-pager`, and the authenticated `/api2/json/nodes/{node}/sensors` response. The agent retains the last successful snapshot after a collection failure, rather than fabricating a new timestamp.

**API 401 / 403.** Log in again on the same scheme, host and port. Check `Sys.Audit` on the exact requested node; the tab uses the selected node, not the `localhost` alias.

**API unavailable after a Proxmox update.** Re-run the reviewed installer. If the patch is incompatible, leave the data private and adapt the registration; never recreate the public JSON link.

**Blank page or old assets after an upgrade.** Hard-refresh the browser and inspect its developer console. Check the local static files. A future PVE change may require adapting this route; no compatibility across all future releases is guaranteed.

**A package install fails.** The installer leaves APT sources alone. Fix repository access separately, then retry. It never runs `apt-get -f`, an operating-system upgrade or autoremove.

## Repository and development

```text
pve-sensors-live/
├── install.sh                  # Generated, self-contained installer
├── README.md                   # This guide
├── LICENSE                     # MIT, without warranty
├── SECURITY.md                 # Threat model and disclosure guidance
├── SHA256SUMS                  # Release file integrity manifest
├── src/
│   ├── install.template.sh     # Installer logic before source embedding
│   ├── pve-sensors-agent.py    # Standard-library collector
│   ├── pve-sensors.service     # Hardened systemd service
│   ├── pve-sensors.defaults    # Default configuration
│   ├── api/                    # Native API module and reversible registration
│   ├── ui/                     # Reversible native-tab and script hooks
│   └── web/                    # Widget, cards, chart and scoped CSS
├── tools/                      # Installer builder and checksum generator
├── tests/                      # Standard-library unit tests
└── docs/                       # Screenshots and release validation notes
```

Edit `src/`, then rebuild and run the tests:

```bash
python3 tools/build_installer.py
python3 tools/build_installer.py --check
python3 -m unittest discover -s tests -v
bash -n install.sh
python3 tools/update_checksums.py
```

Optional development checks are `node --check src/web/pve-sensors.js` and `node tests/test_web.js`. The Python test suite also runs the Perl handler unit tests using core Perl modules. Node.js is **not** a runtime or installation dependency and is never installed by the project.

To inspect the embedded payload without root or any package installation:

```bash
bash install.sh --extract ./extracted-source
```

The extraction directory must not exist. The extracted files are identical to the corresponding source files. Do not publish host backups, terminal transcripts or real raw sensor dumps with changes. Prefer synthetic fixtures, and inspect PNG metadata before adding screenshots.

### Publish a release

Once the workflow is merged into `main`, open **Actions → Release → Run workflow**, select `main` and run it. No additional inputs or secrets are needed; it uses the repository's built-in `GITHUB_TOKEN`.

The workflow reads `VERSION` from `src/install.template.sh`, rebuilds and tests the installer, then publishes a GitHub release such as `v2.1.0` with `install.sh` and its `SHA256SUMS`. The release points to the exact tested commit and becomes the latest release. Installation needs only `install.sh`.

Existing tags and published files are never overwritten. Before the next release, update the version in the sources, rebuild `install.sh`, regenerate `SHA256SUMS` and merge the changes into `main`. If an upload fails, check for an unfinished draft release before retrying.

## License and independence

[MIT](LICENSE). The software and documentation are provided **AS IS, without warranty**. Review the code and test on an appropriate host before relying on it. This is an independent community project and is not affiliated with or endorsed by Proxmox Server Solutions GmbH. Proxmox is a trademark of its respective owner.

## Upstream references

These links document the platform behavior used by the implementation; they are not runtime dependencies.

- [Proxmox pveproxy documentation](https://github.com/proxmox/pve-docs/blob/master/pveproxy.adoc)
- [Proxmox pveproxy static-directory setup](https://github.com/proxmox/pve-manager/blob/master/PVE/Service/pveproxy.pm)
- [Proxmox HTTP static-file handling](https://github.com/proxmox/pve-http-server/blob/master/src/PVE/APIServer/AnyEvent.pm)
- [Debian sensors(1), including JSON output](https://manpages.debian.org/trixie/lm-sensors/sensors.1.en.html)
- [Debian lm-sensors package](https://packages.debian.org/trixie/lm-sensors)
- [systemd execution sandbox and runtime directories](https://www.freedesktop.org/software/systemd/man/systemd.exec.html)
- [Linux hwmon sensor access and update intervals](https://www.kernel.org/doc/html/latest/hwmon/sysfs-interface.html)

- [Proxmox UI template and script load order](https://github.com/proxmox/pve-manager/blob/master/www/index.html.tpl)
- [Proxmox node configuration panel](https://github.com/proxmox/pve-manager/blob/master/www/manager6/node/Config.js)
