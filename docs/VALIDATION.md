# Release validation

## Checks performed for 1.0.0

The following checks were performed on the packaged source before publication:

- **25 Python standard-library unit tests passed.** Coverage includes Intel/AMD labels, multiple CPU packages, numeric validation, firmware sentinel thresholds, unknown-label privacy, HTML-like labels, fixed read-only subprocess arguments, atomic publication, file mode, interval limits, CLI validation, installer extraction, source/payload equivalence, shell syntax and APT safety guards.
- `bash -n install.sh` completed successfully.
- `node --check src/web/pve-sensors.js` completed successfully on the development machine. Node is not required on the Proxmox host.
- `python3 tools/build_installer.py --check` confirmed that the standalone installer matches the readable source files.
- Headless Chromium UI tests with a synthetic in-page snapshot transport passed for live rendering, unique-snapshot chart accumulation, stale data, malformed payload recovery, critical thresholds, text-only rendering of HTML-like labels, zero-RPM messaging, CPU source selection, bounded-history compaction, and desktop/mobile layout.
- Dark desktop, light desktop and 390-pixel mobile screenshots were visually reviewed. They contain simulated data, not production measurements.
- The release tree was checked for source-deployment identifiers and credentials. Screenshot metadata was removed. Python bytecode, temporary files, local test harnesses and host outputs were excluded.

## What these tests do not establish

The browser rendering tests used mocked transport. They did not test a real Proxmox HTTPS server, browser certificate handling, actual CSP enforcement, every visibility/timeout edge case, or a production management network.

This public build has not been installed on the author's live Proxmox host by the release process. Actual sensor accessibility, dynamic-user sandbox behavior, APT operation, startup after a real host reboot, a failing disk, and rollback under every possible system failure have not been integration-tested here. A preceding deployment of the same static-page/RAM-snapshot approach was reported working on Proxmox VE 9.x; that is not blanket certification of this generalized release.

The installer performs host-side sensor, freshness, permissions and local HTTPS checks when it is actually run. Skipping the HTTP check removes that part of verification. These checks are not a penetration test or a guarantee that no vulnerabilities exist.

Performance depends on the hardware, loaded drivers, active viewers and host logging. The release deliberately makes no universal CPU, memory or disk-I/O claim.

## Repeat the portable tests

```bash
python3 tools/build_installer.py --check
python3 -m unittest discover -s tests -v
bash -n install.sh
```

A development-only JavaScript syntax check is:

```bash
node --check src/web/pve-sensors.js
```

Before publishing an edited release, rebuild the installer and run `python3 tools/update_checksums.py` after all source and documentation changes. Checksums detect corruption or changes, not publisher authenticity.
