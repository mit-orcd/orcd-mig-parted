# orcd-mig-parted

A thin wrapper and curated MIG configuration library for [MIT ORCD](https://orcd.mit.edu/) **engaging** GPU servers. It sits on top of NVIDIA’s [`mig-parted`](https://github.com/NVIDIA/mig-parted) tool (`nvidia-mig-parted`) so administrators can apply named, declarative Multi-Instance GPU (MIG) layouts without memorizing low-level `nvidia-smi` workflows.

## Background

[MIG](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/index.html) lets a single datacenter GPU be split into fixed-size “MIG devices” (compute + memory slices). [`nvidia-mig-parted`](https://github.com/NVIDIA/mig-parted) reads a YAML file of named profiles and applies one profile across all GPUs on a node.

This repository provides:

- **`nvidia-mig`** — a small Bash CLI used on engaging nodes (deployed and managed via Salt).
- **`db/config.yaml`** — MIG profiles for engaging **8-GPU** nodes (e.g. 8× A100-class).

On a live server, the wrapper expects the upstream binary and configs to live under `/home/systems/mig/mig-parted` (see [Deployment](#deployment)).

## Requirements

| Component | Notes |
|-----------|--------|
| [`nvidia-mig-parted`](https://github.com/NVIDIA/mig-parted) | Built or installed as `./nvidia-mig-parted` next to this repo on the node |
| NVIDIA driver + MIG-capable GPUs | Ampere or newer (A100, H100, etc.) |
| `nvidia-smi` | Used by `status` |
| Python 3 + PyYAML | Config validation and `list` |
| `systemd` (optional) | Boot-time re-apply via `mig-config-apply` |

Install upstream from [releases](https://github.com/NVIDIA/mig-parted/releases) or build per the [upstream README](https://github.com/NVIDIA/mig-parted#installing-nvidia-mig-parted).

## Quick start

On an engaging node (as root or a privileged admin account):

```bash
cd /home/systems/mig/mig-parted

# Show help and available profile names
./nvidia-mig help

# List named configurations from db/config.yaml
./nvidia-mig list

# Apply a profile (example: heterogeneous 4-GPU MIG layout)
./nvidia-mig apply 4mig-diverse

# Inspect current MIG instances and boot persistence
./nvidia-mig status
```

Applying a configuration **reconfigures GPUs** and may disrupt running jobs. Coordinate with schedulers and users before changing layouts on production nodes.

## Commands

| Command | Description |
|---------|-------------|
| `nvidia-mig apply <config-name>` | Validate `<config-name>` in `db/config.yaml`, then run `nvidia-mig-parted apply -f db/config.yaml -c <config-name>` |
| `nvidia-mig list` | Print all profile names defined under `mig-configs` |
| `nvidia-mig status` | Show `nvidia-smi mig -lgi`, boot-time config from `/etc/mig-config-name`, and `mig-config-apply` systemd state |
| `nvidia-mig help` | Usage summary (default when invoked with no arguments) |

Unknown commands print help and exit with status 1. `apply` without a config name does the same.

The wrapper filters two noisy upstream warnings that are common on ORCD systems (IOMMU FD and PCI device-name lookup); all other `nvidia-mig-parted` output is passed through.

## Configuration profiles

Profiles follow the [`mig-parted` v1 schema](https://github.com/NVIDIA/mig-parted): each name under `mig-configs` is a list of device rules (`devices`, `mig-enabled`, `mig-devices`). Profile names are arbitrary labels; the tool applies whichever name you pass to `apply`.

### Global / all-GPU layouts

| Profile | Summary |
|---------|---------|
| `all-disabled` | MIG off on every GPU |
| `all-enabled` | MIG on, no instances created yet |
| `all-1g.18gb` | Seven `1g.18gb` instances per GPU |
| `all-1g.18gb.me` | One `1g.18gb+me` (media engines) per GPU |
| `all-2g.35gb` | Three `2g.35gb` instances per GPU |
| `all-3g.71gb` | Two `3g.71gb` instances per GPU |
| `all-4g.71gb` | One `4g.71gb` instance per GPU |
| `all-7g.141gb` | One near-full-GPU `7g.141gb` instance per GPU |
| `all-mixed` | Mixed `1g` / `2g` / `3g` on every GPU |
| `8mig-dense` | Max small-instance density (`1g.18gb` × 7) on all GPUs |
| `8mig-balanced` | Uniform `2g.35gb` × 3 on all GPUs |
| `8mig-role-based` | One GPU per “role” (ultra-big, large, balanced, medium-dense, max-density) |

### Partial-GPU layouts (remaining GPUs full, non-MIG)

Device indices refer to the 8-GPU layout in `db/config.yaml`.

| Profile | Summary |
|---------|---------|
| `2mig-mixed`, `2mig-balanced`, `2mig-optimized-balanced`, `2mig-diverse` | MIG on two GPUs; others disabled |
| `2mig-oneoff-balanced` | MIG on GPUs 5–6 only |
| `4mig-mixed`, `4mig-balanced`, `4mig-diverse`, `4mig-optimized-mixed` | MIG on four GPUs; first four full |
| `4mig-media-dense` | Four MIG GPUs with `1g.18gb+me` + six `1g.18gb` (video/transcode friendly) |
| `1mig-big` | Single `7g.141gb` on one GPU; rest full |
| `6mig-balanced` | Two full GPUs + six GPUs with `2g.35gb` × 3 |

`4mig-diverse` is the canonical heterogeneous layout referenced in wrapper examples: one “big”, one “balanced”, one “medium”, and one “density” GPU among the MIG-enabled set.

Run `nvidia-mig list` on a node for the authoritative name list from the deployed YAML.

## Deployment

Engaging MIG nodes are configured with Salt. This repo ships the state under [`mig-server/init.sls`](mig-server/init.sls) (Salt path `engaging/role/mig-server` in the ORCD file root).

### Prerequisites on the node

Before or alongside the Salt role, ensure `/home/systems/mig/mig-parted` contains:

| File | Source |
|------|--------|
| `nvidia-mig` | This repo |
| `db/config.yaml` | This repo |
| `nvidia-mig-parted` | [NVIDIA/mig-parted](https://github.com/NVIDIA/mig-parted) binary |

The Salt state creates the install directory and boot integration; it does **not** copy the wrapper, YAML, or upstream binary (those are deployed by your existing engaging file-sync or packaging process).

### Pillar: desired MIG profile

Set the profile name in pillar as `mig-server:state`. When present, Salt writes `/etc/mig-config-name`, runs an immediate apply (unless MIG is already enabled), and wires boot-time re-apply to that name.

Example (node or group pillar):

```yaml
mig-server:
  state: 4mig-diverse
```

Use any name from `db/config.yaml` / `nvidia-mig list`. Omit `mig-server:state` or leave it empty to install only the directory, symlink, and systemd unit without changing GPU layout or writing `/etc/mig-config-name`.

### Apply the Salt state

On the target engaging host (as root):

```bash
salt-call state.apply engaging.role.mig-server
```

From the Salt master for one minion:

```bash
salt '<minion-id>' state.apply engaging.role.mig-server
```

Test with `test=True` before changing production nodes:

```bash
salt-call state.apply engaging.role.mig-server test=True
```

### What the state configures

| Step | Action |
|------|--------|
| Pre-clean | Stop `mig-config-apply` if running; remove a legacy unit file under `/etc/systemd/system/` |
| Install dir | Create `/home/systems/mig/mig-parted` (`0755`) |
| CLI symlink | `/usr/local/sbin/nvidia-mig` → `/home/systems/mig/mig-parted/nvidia-mig` |
| Boot config | If pillar `mig-server:state` is set, write its value to `/etc/mig-config-name` |
| Boot script | Install `/usr/local/sbin/apply-mig-on-boot.sh` — waits for NFS-backed `/home/systems/mig/mig-parted/nvidia-mig`, then runs it with `bash` (not the `/usr/local/sbin` symlink) |
| systemd | Install and **enable** `mig-config-apply.service` (oneshot, `RequiresMountsFor` install dir, runs before `slurmd`, 600s timeout); **does not start** during `state.apply` |
| Immediate apply | If pillar is set and `nvidia-mig` is executable: `timeout 180 nvidia-mig apply <state>` logged to `/var/log/mig-apply.log` |

After apply, monitor a long-running MIG operation with:

```bash
tail -f /var/log/mig-apply.log
nvidia-mig status
```

### Install layout on disk

```
/home/systems/mig/mig-parted/
├── nvidia-mig              # wrapper (this repo)
├── nvidia-mig-parted       # upstream binary
└── db/
    └── config.yaml         # MIG profiles

/usr/local/sbin/nvidia-mig           # symlink → wrapper
/usr/local/sbin/apply-mig-on-boot.sh # boot helper (Salt-managed)
/etc/mig-config-name                 # profile name (when pillar set)
/etc/systemd/system/mig-config-apply.service
/var/log/mig-apply.log               # apply log
```

The wrapper `cd`s into `/home/systems/mig/mig-parted` before running; paths in `nvidia-mig` are relative to that directory.

### Boot-time behavior

On reboot, `mig-config-apply.service` runs the boot script, which:

1. Exits if `/etc/mig-config-name` is missing.
2. Skips apply if `nvidia-smi mig -lgi` already shows MIG enabled.
3. Otherwise runs `bash /home/systems/mig/mig-parted/nvidia-mig apply <name>` (after waiting for the NFS path to be executable).

The `/usr/local/sbin/nvidia-mig` symlink is for interactive use once `/home` is mounted; boot does **not** rely on it (exit 127 if NFS is late).

`nvidia-mig status` shows the persisted name and whether `mig-config-apply` is active/enabled. Changing the long-term profile on a node means updating pillar `mig-server:state` and re-running the Salt state (or editing `/etc/mig-config-name` and rebooting, if you manage it outside Salt).

## Adding or changing profiles

1. Edit `db/config.yaml`.
2. Follow upstream rules: device indices, valid MIG profile strings for your GPU SKU, and consistent `version: v1`.
3. Validate syntax: `python3 -c "import yaml; yaml.safe_load(open('db/config.yaml'))"`.
4. Test on a maintenance window: `nvidia-mig apply <new-name>` then `nvidia-mig status` and `nvidia-smi mig -lgi`.
5. Update pillar `mig-server:state` if the node should use the new profile at boot, then run `salt-call state.apply engaging.role.mig-server`.

Use [`nvidia-mig-parted export`](https://github.com/NVIDIA/mig-parted#export-the-current-mig-config) on a manually configured node to capture an existing layout as a starting point.

## Consistency audit and deployment gaps

This section records cross-checks across `nvidia-mig`, `mig-server/init.sls`, `db/config.yaml`, and the README. Use it when hardening production deployment.

### Fixed in this repo (recent)

| Issue | Resolution |
|-------|------------|
| Salt `apply-mig-now` typo `MIG.*Enaed` | Corrected to `MIG.*Enabled` so immediate apply skips when MIG is already up |
| systemd unit `After=remote-frget` | Corrected to `remote-fs.target` |
| `nvidia-mig apply` used `exec` with `grep` and `pipefail` | Removed `exec`; exit status follows `nvidia-mig-parted`, not `grep` |
| Hard-coded `cd` only | Wrapper resolves install dir via `readlink -f` on the script; falls back to `MIG_PARTED_DIR` / `/home/systems/mig/mig-parted` |
| Empty pillar `mig-server:state: ""` | Salt treats empty string as unset |

### Remaining gaps (recommended fixes)

| Gap | Risk | Recommended solution |
|-----|------|----------------------|
| Salt does not deploy `nvidia-mig`, `db/config.yaml`, or `nvidia-mig-parted` | Symlink or apply runs before files exist; pillar apply silently skipped (`onlyif: test -x wrapper`) | Enable [`mig-server/deploy-repo.sls`](mig-server/deploy-repo.sls): mirror repo files to `salt://engaging/role/mig-server/files/` (CI/gitfs), `include` from `init.sls`, require `deploy-*` before `nvidia-mig-symlink` |
| No Salt check that pillar profile exists in YAML | `nvidia-mig apply` fails at runtime | Add `cmd.run` with `nvidia-mig list` + grep, or `file.serialize` validation in CI |
| Boot / Salt skip when “MIG enabled”, not when “desired profile applied” | Changing `mig-server:state` does not re-layout GPUs until manual `nvidia-mig apply` or MIG reset | Document as policy; optional: compare `nvidia-mig-parted assert -f … -c <name>` in boot script instead of grep |
| `list_configs` claims grep fallback but does not grep | Misleading error when PyYAML missing | Install `python3-pyyaml` in base image, or implement grep fallback |
| `nvidia-mig-parted` binary source of truth | Version drift across nodes | Pin version in pillar; deploy via `file.managed` from internal artifact (see commented block in `deploy-repo.sls`) |
| Single `CONFIG_FILE` path | Cannot switch configs without editing wrapper | Optional pillar `mig-server:config_file` read by wrapper (future) |

### Optional Salt include

After files are on the fileserver:

```yaml
# top of mig-server/init.sls (after directory is defined)
include:
  - .deploy-repo
```

Reorder `require` on `nvidia-mig-symlink` to depend on `deploy-nvidia-mig-wrapper`.

### Profile vs README

All names in the README tables exist in `db/config.yaml` (24 profiles). Partial layouts use GPUs `6–7` or `5–6` for `2mig-*` names; `2mig-oneoff-balanced` uses GPUs **5 and 6** (not 5–7). `8mig-role-based` assigns roles across eight GPUs with some indices sharing the same layout block.

## Troubleshooting

| Symptom | Things to check |
|---------|------------------|
| `Cannot cd to /home/systems/mig/mig-parted` | Install path or Salt sync; clone/copy this repo to the expected location |
| `Config '…' not found` | Typo or profile name not defined in `db/config.yaml` |
| Apply fails / GPU reset errors | Unload `nvidia_drm` if loaded; see [mig-parted #181](https://github.com/NVIDIA/mig-parted/issues/181) |
| `unable to get device name` warnings | Run `sudo update-pciids` (upstream [known issue](https://github.com/NVIDIA/mig-parted#known-issues)) |
| Boot config not applied | `systemctl status mig-config-apply`, `journalctl -u mig-config-apply`, `/var/log/mig-apply.log` |
| `status=127` on boot, `nvidia-mig: No such file` | `/home` NFS not mounted when service ran; re-apply Salt state (boot script waits for wrapper on NFS), then `systemctl start mig-config-apply` |
| Salt apply seemed stuck | State only **enables** the unit; check `/var/log/mig-apply.log` for the timed immediate apply |
| Pillar set but no immediate apply | Wrapper missing or not executable at `/home/systems/mig/mig-parted/nvidia-mig` |

## Repository contents

```
.
├── README.md           # this file
├── nvidia-mig          # ORCD wrapper script
├── mig-server/
│   ├── init.sls        # Salt state (engaging.role.mig-server)
│   └── deploy-repo.sls # optional file.deploy from Salt fileserver
└── db/
    └── config.yaml     # MIG profiles
```

## Related links

- [NVIDIA/mig-parted](https://github.com/NVIDIA/mig-parted) — upstream partition editor
- [MIG User Guide](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/index.html) — NVIDIA documentation
- [mig-parted systemd deployment](https://github.com/NVIDIA/mig-parted/tree/main/deployments/systemd) — boot persistence pattern

## License

Configuration YAML in `db/` derives from NVIDIA `mig-parted` examples and ORCD-specific extensions. The `nvidia-mig` wrapper is MIT ORCD infrastructure code; comply with NVIDIA’s license for `nvidia-mig-parted` when redistributing the binary.
