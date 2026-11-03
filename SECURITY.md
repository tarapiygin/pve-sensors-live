# Security policy and deployment boundary

PVE Sensors Live is an unauthenticated, read-only static dashboard served from the Proxmox management origin. It is not a Proxmox authentication plugin and not a substitute for access controls around the management network.

## Intended trust boundary

An administrator reviews and installs the code as root on the physical host. Package installation uses that host's existing APT trust configuration. During normal operation, a dynamically allocated, non-root service identity reads the already-exposed hardware monitoring interface. The service writes only its runtime snapshot and temporary files. The existing web server reads the public snapshot and serves root-owned static assets.

Anyone who can reach the URL can read the snapshot, regardless of whether they have a Proxmox account. A JavaScript login check would not protect the underlying JSON and is intentionally not presented as authentication. Do not expose this dashboard on an untrusted network without a suitable access-control layer.

## Defensive measures

- No root collector, shared `nobody` service, extra capabilities, SUID helper, shell interpolation of sensor input or extra listener.
- The preflight uses `nobody` only to verify read access; runtime uses `DynamicUser=yes`.
- A private network namespace and `RestrictAddressFamilies=AF_UNIX` prevent ordinary TCP/UDP communication from the collector.
- Installed application and web files remain outside the collector's writable directory.
- JSON is built from a narrow schema. Raw chip strings, custom labels and device identity are not forwarded.
- Atomic publication prevents readers from seeing half-written JSON.
- The browser inserts sensor strings as text, omits credentials from snapshot requests and loads no external assets.
- The installer refuses an unmanaged file collision, serializes its own runs, backs up managed files, and offers best-effort rollback.
- There are no update hooks, remote code downloads, APT source edits or unattended sensor-detection commands.

These measures reduce risk; they are not a security certification. Code served on the Proxmox management origin is privileged from the administrator's browser perspective. Review changes to the JavaScript with the same care as other management-interface code.

## Known limitations

The runtime snapshot is intentionally world-readable and publicly served. Sensor topology, temperatures and fan activity can reveal workload information even when explicit identifiers are omitted. Numeric sensor IDs are ordinal labels, not a durable inventory identity, and can change when hardware enumeration changes.

`/run` normally uses tmpfs, but swap, service journals and Proxmox HTTP access logs may still cause disk writes. The project does not change host logging or memory-management policy.

Collection, filesystem permissions and sandbox behavior depend on the installed distribution, systemd and hardware drivers. The static URL is not a supported extension API. An incompatible Proxmox update may break the dashboard. Tests do not prove the absence of vulnerabilities.

Backups remain under `/var/backups/pve-sensors/` for administrator recovery and may contain previous locally edited project files. They must not be committed to a public repository. The uninstaller intentionally leaves backups and package dependencies behind.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting feature on the repository if the maintainer has enabled it. Otherwise, open a minimal issue asking for a private contact method without disclosing exploit details or secrets. The repository owner must enable private reporting in GitHub settings; this file cannot enable it automatically.

Do not attach passwords, tickets, API tokens, `/etc/pve` content, unredacted logs, host backups or production screenshots. Prefer a minimal synthetic reproduction. There is no guaranteed support or response time.
