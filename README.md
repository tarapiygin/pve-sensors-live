# PVE Sensors Live

Live hardware temperatures and fan speeds in **Proxmox VE → Node → Sensors**.

## Install

Run in an interactive **root shell on a Proxmox VE 9.x host** (not inside a VM or container):

```bash
curl -fsSL https://raw.githubusercontent.com/tarapiygin/pve-sensors-live/main/install.sh -o install.sh && bash install.sh
```

Confirm the installer prompts. The script is self-contained; no repository clone or local build is needed. It installs `lm-sensors` if missing and reloads `pvedaemon`/`pveproxy`; VMs and containers keep running.

After installation, hard-refresh the Proxmox web interface, sign in and open **Node → Sensors**. Your account needs `Sys.Audit` on that node. In a cluster, install on each node you use.

Run the same command to update or restore integration after a `pve-manager` update.
