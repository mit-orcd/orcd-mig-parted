#!/bin/bash
# Manual deploy for orcd-mig-parted.
# Same node result as Salt state engaging.role.mig-server, and it also
# copies nvidia-mig and db/config.yaml (Salt's init.sls does not).
# Keep the boot script and unit in sync with mig-server/init.sls and
# deploy/ansible/roles/mig-server/templates/.

set -euo pipefail

DEST="/home/systems/mig/mig-parted"
SYMLINK="/usr/local/sbin/nvidia-mig"
PERSIST="/etc/mig-config-name"
BOOT_SCRIPT="/usr/local/sbin/apply-mig-on-boot.sh"
UNIT="/etc/systemd/system/mig-config-apply.service"
APPLY_LOG="/var/log/mig-apply.log"
WAIT_SECS=300
WAIT_INTERVAL=5
APPLY_TIMEOUT=180

STATE=""
BINARY=""
SRC=""
NO_APPLY=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: deploy-mig.sh [options]

Install nvidia-mig, db/config.yaml, the /usr/local/sbin symlink, and
mig-config-apply.service. When --state is set, write /etc/mig-config-name
and apply that profile unless MIG is already enabled.

Options:
  --state NAME     Profile from db/config.yaml (pillar mig-server:state).
                   Omit to install boot integration without changing GPUs
                   or /etc/mig-config-name.
  --binary PATH    Copy this nvidia-mig-parted binary into the install dir.
  --src DIR        Repo checkout to copy from (default: this repo).
  --dest DIR       Install directory (default: /home/systems/mig/mig-parted).
  --no-apply       Write boot config but do not run nvidia-mig apply.
  --dry-run        Print actions without changing the node.
  -h, --help       Show this help.

Examples:
  sudo ./deploy/deploy-mig.sh --state 4mig-diverse
  sudo ./deploy/deploy-mig.sh --state 4mig-diverse --binary /path/to/nvidia-mig-parted
  sudo ./deploy/deploy-mig.sh --no-apply
  ./deploy/deploy-mig.sh --dry-run --state 4mig-diverse
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'dry-run:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

write_file() {
  local dest=$1 mode=$2
  local tmp dest_dir
  dest_dir=$(dirname "$dest")
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "dry-run: write $dest (mode $mode)"
    cat >/dev/null
    return 0
  fi
  install -d -m 0755 -o root -g root "$dest_dir"
  tmp=$(mktemp)
  cat >"$tmp"
  install -m "$mode" -o root -g root "$tmp" "$dest"
  rm -f "$tmp"
}

copy_file() {
  local src=$1 dest=$2 mode=$3
  local dest_dir
  dest_dir=$(dirname "$dest")
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "dry-run: install -m $mode $src -> $dest"
    return 0
  fi
  run install -d -m 0755 -o root -g root "$dest_dir"
  if [[ -e "$dest" && "$(readlink -f "$src")" == "$(readlink -f "$dest")" ]]; then
    run chmod "$mode" "$dest"
    return 0
  fi
  run install -m "$mode" -o root -g root "$src" "$dest"
}

validate_state() {
  [[ -z "$STATE" ]] && return 0
  [[ "$STATE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid profile name: $STATE"
  python3 - "$SRC/db/config.yaml" "$STATE" <<'PY'
import sys
path, name = sys.argv[1], sys.argv[2]
try:
    import yaml
except ImportError:
    yaml = None
if yaml is not None:
    with open(path) as handle:
        data = yaml.safe_load(handle) or {}
    if name not in data.get("mig-configs", {}):
        sys.stderr.write("profile %r is not in %s\n" % (name, path))
        sys.exit(1)
    sys.exit(0)
prefix = "  " + name + ":"
with open(path) as handle:
    if any(line.startswith(prefix) for line in handle):
        sys.stderr.write(
            "warning: python3-pyyaml is not installed; matched the profile as a YAML key.\n"
        )
        sys.exit(0)
sys.stderr.write("profile %r is not in %s\n" % (name, path))
sys.exit(1)
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state)
      [[ $# -ge 2 ]] || die "--state requires a profile name"
      STATE=$2
      shift 2
      ;;
    --binary)
      [[ $# -ge 2 ]] || die "--binary requires a path"
      BINARY=$2
      shift 2
      ;;
    --src)
      [[ $# -ge 2 ]] || die "--src requires a directory"
      SRC=$2
      shift 2
      ;;
    --dest)
      [[ $# -ge 2 ]] || die "--dest requires a directory"
      DEST=$2
      shift 2
      ;;
    --no-apply)
      NO_APPLY=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1 (try --help)"
      ;;
  esac
done

SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
REPO_ROOT=$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)
if [[ -z "$SRC" ]]; then
  SRC=$REPO_ROOT
fi
SRC=$(readlink -f "$SRC")

command -v python3 >/dev/null 2>&1 || die "python3 is required"
[[ -f "$SRC/nvidia-mig" ]] || die "wrapper not found: $SRC/nvidia-mig"
[[ -f "$SRC/db/config.yaml" ]] || die "config not found: $SRC/db/config.yaml"
if [[ -n "$BINARY" ]]; then
  [[ -f "$BINARY" ]] || die "binary not found: $BINARY"
fi

validate_state

if [[ "$DRY_RUN" -eq 0 && "$(id -u)" -ne 0 ]]; then
  die "run as root (or pass --dry-run)"
fi
if [[ "$DRY_RUN" -eq 0 ]]; then
  command -v systemctl >/dev/null 2>&1 || die "systemctl is required"
fi

if [[ -n "$STATE" && "$NO_APPLY" -eq 0 ]]; then
  if [[ "$DRY_RUN" -eq 0 ]]; then
    python3 -c 'import yaml' 2>/dev/null || die "python3-pyyaml is required to apply a profile"
  fi
  if [[ ! -f "$BINARY" && ! -f "$DEST/nvidia-mig-parted" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "dry-run: nvidia-mig-parted is missing; a real run stops unless you pass --binary or --no-apply"
    else
      die "nvidia-mig-parted is missing. Pass --binary PATH, or re-run with --no-apply to install boot integration only."
    fi
  fi
fi

if [[ "$DRY_RUN" -eq 0 && -f "$UNIT" ]]; then
  timeout 30 systemctl stop mig-config-apply || true
elif [[ "$DRY_RUN" -eq 1 && -f "$UNIT" ]]; then
  echo "dry-run: timeout 30 systemctl stop mig-config-apply"
fi

run install -d -m 0755 -o root -g root "$DEST"
run install -d -m 0755 -o root -g root "$DEST/db"
copy_file "$SRC/nvidia-mig" "$DEST/nvidia-mig" 0755
copy_file "$SRC/db/config.yaml" "$DEST/db/config.yaml" 0644
if [[ -n "$BINARY" ]]; then
  copy_file "$BINARY" "$DEST/nvidia-mig-parted" 0755
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "dry-run: ln -sfn $DEST/nvidia-mig $SYMLINK"
else
  ln -sfn "$DEST/nvidia-mig" "$SYMLINK"
fi

if [[ -n "$STATE" ]]; then
  printf '%s\n' "$STATE" | write_file "$PERSIST" 0644
fi

write_file "$BOOT_SCRIPT" 0755 <<EOF
#!/bin/bash
# Installed by deploy/deploy-mig.sh.
# Keep in sync with mig-server/init.sls and deploy/ansible/roles/mig-server/templates/.
set -euo pipefail
CONFIG_FILE="$PERSIST"
MIG_WRAPPER="$DEST/nvidia-mig"
MIG_DIR="$DEST"
WAIT_SECS=$WAIT_SECS
WAIT_INTERVAL=$WAIT_INTERVAL

wait_for_mig_wrapper() {
  local elapsed=0
  while [ ! -x "\$MIG_WRAPPER" ]; do
    if [ "\$elapsed" -ge "\$WAIT_SECS" ]; then
      echo "ERROR: \$MIG_WRAPPER not executable after \${WAIT_SECS}s (check /home NFS mount)" | tee -a "$APPLY_LOG"
      return 1
    fi
    echo "\$(date) waiting for \$MIG_WRAPPER (\${elapsed}s, /home mount?)" | tee -a "$APPLY_LOG"
    sleep "\$WAIT_INTERVAL"
    elapsed=\$((elapsed + WAIT_INTERVAL))
  done
}

if [ ! -f "\$CONFIG_FILE" ]; then
    echo "No MIG config defined. Skipping." | tee -a "$APPLY_LOG"
    exit 0
fi
wait_for_mig_wrapper || exit 1
if nvidia-smi mig -lgi 2>/dev/null | grep -q "MIG.*Enabled"; then
    echo "MIG already enabled → skipping apply" | tee -a "$APPLY_LOG"
    exit 0
fi
CONFIG_NAME=\$(cat "\$CONFIG_FILE")
echo "\$(date) === MIG boot apply starting: \$CONFIG_NAME ===" | tee -a "$APPLY_LOG"
/bin/bash "\$MIG_WRAPPER" apply "\$CONFIG_NAME" 2>&1 | tee -a "$APPLY_LOG"
echo "\$(date) === MIG boot apply completed ===" | tee -a "$APPLY_LOG"
EOF

write_file "$UNIT" 0644 <<EOF
# Installed by deploy/deploy-mig.sh.
# Keep in sync with mig-server/init.sls and deploy/ansible/roles/mig-server/templates/.
[Unit]
Description=Apply NVIDIA MIG configuration on boot
After=network-online.target remote-fs.target
Before=slurmd.service
Wants=network-online.target remote-fs.target
RequiresMountsFor=$DEST

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BOOT_SCRIPT
TimeoutStartSec=600

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "dry-run: systemctl daemon-reload"
  echo "dry-run: systemctl enable mig-config-apply"
else
  systemctl daemon-reload
  systemctl enable mig-config-apply
fi

if [[ -n "$STATE" && "$NO_APPLY" -eq 0 ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "dry-run: nvidia-mig apply $STATE (skip if MIG is already enabled; log $APPLY_LOG)"
  else
    set -o pipefail
    (
      echo "$(date) === manual immediate MIG apply starting: ${STATE} ==="
      if nvidia-smi mig -lgi 2>/dev/null | grep -q "MIG.*Enabled"; then
        echo "MIG already enabled → skipping apply"
        exit 0
      fi
      timeout "$APPLY_TIMEOUT" /bin/bash "$DEST/nvidia-mig" apply "$STATE"
      rc=$?
      echo "$(date) === manual immediate MIG apply finished ==="
      exit "$rc"
    ) 2>&1 | tee "$APPLY_LOG"
    apply_rc=${PIPESTATUS[0]}
    [[ "$apply_rc" -eq 0 ]] || exit "$apply_rc"
  fi
fi

echo "MIG setup complete."
echo "  install dir: $DEST"
echo "  symlink:     $SYMLINK"
if [[ -n "$STATE" ]]; then
  echo "  boot profile: $STATE ($PERSIST)"
else
  echo "  boot profile: unchanged (no --state; $PERSIST left as-is)"
fi
echo "  service:     mig-config-apply enabled, not started"
echo "Check: nvidia-mig status"
if [[ -n "$STATE" && "$NO_APPLY" -eq 0 ]]; then
  echo "Log:   tail -f $APPLY_LOG"
fi
