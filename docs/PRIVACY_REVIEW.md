# Publication privacy review

## Scope

The release archive contains the self-contained installer, readable application sources, documentation, tests, license, checksums and synthetic screenshots. It does not contain a Git history, production sensor exports, service journals, configuration backups, terminal transcripts or browser profiles.

The included files were checked for personal names, private account/repository names, infrastructure domains, the original management address, host-specific paths, serial/MAC-like identifiers, secret-key material, access tokens and credentials. No source deployment identity was retained in the release. Intentional loopback addresses used for local verification are not deployment addresses.

The copyright notice uses the project name rather than a personal name or email address. The distribution has a neutral project/service namespace. No hardware model is required by, or embedded in, the installer.

## Screenshot provenance

The screenshots were rendered from the included dashboard with synthetic sensor cards and simulated chart history. They are labelled as simulated previews. There is no browser address bar, terminal prompt, username, actual node name, device model, real sensor export or management URL. PNGs were re-encoded without textual or EXIF metadata.

## Runtime data policy

The authenticated JSON contains only generated sensor IDs, generated labels, categories, roles, numeric measurements, allowed thresholds, timestamps, sampling metadata and a random identifier for the current collector process. The random identifier changes on restart and is not derived from the machine ID, DMI, hostname or network configuration.

Custom `sensors` labels and raw chip names are used only locally for classification. They are not copied to the runtime snapshot. Unknown channels receive generated labels. Synthetic unit tests check that a custom label containing an arbitrary private identifier does not reach the JSON.

These controls reduce explicit identification. They do not guarantee anonymity: the number and type of sensors and their changing values can disclose coarse hardware and workload information.

## Before publishing future changes

Inspect screenshots, image metadata and any newly added fixtures. Do not commit host-generated runtime snapshots, backups or logs. Review Git author/email settings separately: this archive contains no Git history and cannot control the identity GitHub attaches to commits made after publication.
