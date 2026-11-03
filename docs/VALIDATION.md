# Release validation

## Native Sensors tab and migration (issues #2 and #3, 2.1.0)

- The Python suite covers the native UI hook apply/reapply/remove paths, incompatible anchors, preservation of unrelated edits, clean/v1 migration through the actual installer helpers, rollback and uninstall. Host services and filesystem paths are stubbed or temporary.
- `node tests/test_web.js` passes 80 assertions with synthetic ExtJS/DOM/HTTP objects: selected-node requests, session/permission errors, rendering state, 500 ms polling, no overlapping requests, panel/document visibility, hide/show abort races, destruction cleanup and independent chart histories.
- API/UI patch applicability is checked before replacing upstream files. The standalone HTML file is no longer in the payload; both old HTML and JSON paths are removed, including on rollback.
- The UI patches were applied, reapplied and removed against upstream `www/manager6/node/Config.js` blob `217ee284c0784e93ff14887c28fcfa43e4774e92` and `www/index.html.tpl` blob `125c1046b852bcde33b0bf6a282dbfca8b5e7f19`; removal reproduced the source exactly.

These are portable tests, not a real Proxmox installation or browser rendering test. No Chromium executable or live PVE node was available. The snapshots below refer to earlier versions. Before merging, obtain third-party review. On a test PVE node, hard-refresh the interface and check Node → Sensors with node-scoped `Sys.Audit`, switch between nodes/views, check 401/403, and confirm that leaving Sensors stops requests and reopening resets its history. Test install/upgrade/reinstall/uninstall, host service reloads and cluster forwarding on the target PVE version.

## Authenticated API change (issue #1)

Portable checks performed for 2.0.0:

- 40 Python tests pass, including the 16-assertion Perl handler harness.
- The handler tests verify the native node-scoped permission declaration, GET-only registration, node proxying, fixed snapshot path, current data and generic errors. PVE module boundaries are stubbed; these are not real ticket/ACL tests.
- Installer HTTP probe tests accept missing-file 404/500 responses, reject measurements even in an error body, keep API denial at 401, and reject network failures, successful public responses and surviving files or dangling symlinks.
- Migration tests exercise the installer's rollback functions and incompatible-patch path in temporary directories: project files are restored and the public JSON link stays removed.
- Patch apply/reapply/remove tests preserve unrelated changes and reject conflicting routes or modified markers. Apply/remove was also checked against the upstream `Nodes.pm` blob `df0b2c2d90b19bde1be069cda523eb58454d8913` from `proxmox/pve-manager`.
- JavaScript transport tests cover the API `data` envelope, same-origin credentials, 401/403/503 and absence of a public fallback. Bash/JavaScript syntax and installer payload equivalence pass.

No live Proxmox host was available for this change. Real session/ACL enforcement, cluster forwarding, systemd reload behavior and end-to-end installation still require the host smoke checks below. Earlier screenshot/rendering checks describe v1 only.

### Live-host smoke checks

Run the installer on a test PVE node, then check `/api2/json/nodes/{node}/sensors` using the actual node name and existing Proxmox browser sessions:

| Request | Expected result |
| --- | --- |
| No session, or an expired/invalid session | 401; no measurements |
| Valid user without node `Sys.Audit` | 403; no measurements |
| Valid user with `Sys.Audit` only on that node | 200 with the current sanitized snapshot under `data` |
| Same user requesting a different unauthorized node | 403; no measurements |
| Authorized user requesting another installed cluster node | That node's snapshot, through native forwarding |
| Old `/pve2/js/pve-sensors.json` and `/pve2/js/pve-sensors.html` URLs, with or without a session | 404 or 500 without measurements; public file/symlink absent |
| Authorized user while the runtime snapshot is absent or invalid | Generic 503 |

Confirm that reinstall succeeds, uninstall preserves unrelated edits in all three patched Proxmox files, and an incompatible patch does not recreate the old static link. The installer itself checks anonymous denial and removal of the public JSON URL unless `--skip-http-check` is supplied. It does not collect credentials for positive authorization tests.

## Earlier checks performed for 1.0.0

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
