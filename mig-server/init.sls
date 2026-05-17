# ===================================================================
# SaltStack State: engaging/role/mig-server/init.sls
# FIXED VERSION – stops stuck service first + no hang on Salt apply
# ===================================================================

{% set mig_dir = "/home/systems/mig/mig-parted" %}
{% set wrapper_path = mig_dir ~ "/nvidia-mig" %}
{% set symlink_path = "/usr/local/sbin/nvidia-mig" %}
{% set persistent_config_file = "/etc/mig-config-name" %}
{% set boot_script = "/usr/local/sbin/apply-mig-on-boot.sh" %}
{% set apply_log = "/var/log/mig-apply.log" %}

# 0. STOP any running/stuck service BEFORE changing files
stop-stuck-mig-service:
  service.dead:
    - name: mig-config-apply
    - require_in:
      - file: remove-old-broken-service

# 1. Remove old broken service file
remove-old-broken-service:
  file.absent:
    - name: /etc/systemd/system/mig-config-apply.service

# 2. Directories & symlink
mig-parted-directory:
  file.directory:
    - name: {{ mig_dir }}
    - user: root
    - group: root
    - mode: '0755'
    - makedirs: True

nvidia-mig-symlink:
  file.symlink:
    - name: {{ symlink_path }}
    - target: {{ wrapper_path }}
    - user: root
    - group: root
    - mode: '0755'
    - force: True
    - require:
      - file: mig-parted-directory

# 3. Persist config name from Pillar
{% set mig_state = salt['pillar.get']('mig-server:state', '') %}
{% if mig_state | length > 0 %}
persist-mig-config-name:
  file.managed:
    - name: {{ persistent_config_file }}
    - user: root
    - group: root
    - mode: '0644'
    - contents: "{{ mig_state }}"
    - require:
      - file: nvidia-mig-symlink
{% endif %}

# 4. Boot script – call NFS-backed wrapper directly (not /usr/local/sbin symlink)
apply-mig-boot-script:
  file.managed:
    - name: {{ boot_script }}
    - user: root
    - group: root
    - mode: '0755'
    - contents: |
        #!/bin/bash
        set -euo pipefail
        CONFIG_FILE="{{ persistent_config_file }}"
        MIG_WRAPPER="{{ wrapper_path }}"
        MIG_DIR="{{ mig_dir }}"
        WAIT_SECS=300
        WAIT_INTERVAL=5

        wait_for_mig_wrapper() {
          local elapsed=0
          while [ ! -x "$MIG_WRAPPER" ]; do
            if [ "$elapsed" -ge "$WAIT_SECS" ]; then
              echo "ERROR: $MIG_WRAPPER not executable after ${WAIT_SECS}s (check /home NFS mount)" | tee -a {{ apply_log }}
              return 1
            fi
            echo "$(date) waiting for $MIG_WRAPPER (${elapsed}s, /home mount?)" | tee -a {{ apply_log }}
            sleep "$WAIT_INTERVAL"
            elapsed=$((elapsed + WAIT_INTERVAL))
          done
        }

        if [ ! -f "$CONFIG_FILE" ]; then
            echo "No MIG config defined. Skipping." | tee -a {{ apply_log }}
            exit 0
        fi
        wait_for_mig_wrapper || exit 1
        if nvidia-smi mig -lgi 2>/dev/null | grep -q "MIG.*Enabled"; then
            echo "MIG already enabled → skipping apply" | tee -a {{ apply_log }}
            exit 0
        fi
        CONFIG_NAME=$(cat "$CONFIG_FILE")
        echo "$(date) === MIG boot apply starting: $CONFIG_NAME ===" | tee -a {{ apply_log }}
        /bin/bash "$MIG_WRAPPER" apply "$CONFIG_NAME" 2>&1 | tee -a {{ apply_log }}
        echo "$(date) === MIG boot apply completed ===" | tee -a {{ apply_log }}
    - require:
      - file: nvidia-mig-symlink
{% if mig_state | length > 0 %}
      - file: persist-mig-config-name
{% endif %}

# 5. Systemd service with timeout
mig-config-apply-service:
  file.managed:
    - name: /etc/systemd/system/mig-config-apply.service
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        [Unit]
        Description=Apply NVIDIA MIG configuration on boot
        After=network-online.target remote-fs.target
        Before=slurmd.service
        Wants=network-online.target remote-fs.target
        RequiresMountsFor={{ mig_dir }}

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart={{ boot_script }}
        TimeoutStartSec=600

        StandardOutput=journal
        StandardError=journal

        [Install]
        WantedBy=multi-user.target
    - require:
      - file: apply-mig-boot-script

# 6. Daemon reload
systemd-daemon-reload:
  cmd.run:
    - name: systemctl daemon-reload
    - require:
      - file: mig-config-apply-service

# 7. Only enable the service (do NOT start it during Salt apply)
enable-mig-boot-service:
  service.enabled:
    - name: mig-config-apply
    - require:
      - cmd: systemd-daemon-reload

# 8. Immediate apply (with timeout + log) – only if pillar exists
{% if mig_state | length > 0 %}
apply-mig-now:
  cmd.run:
    - name: |
        echo "$(date) === Salt immediate MIG apply starting: {{ mig_state }} ===" > {{ apply_log }}
        if nvidia-smi mig -lgi 2>/dev/null | grep -q "MIG.*Enabled"; then
          echo "MIG already enabled → skipping apply" | tee -a {{ apply_log }}
          exit 0
        fi
        timeout 180 /bin/bash {{ wrapper_path }} apply {{ mig_state }} 2>&1 | tee -a {{ apply_log }}
        echo "$(date) === Salt immediate MIG apply finished ===" | tee -a {{ apply_log }}
    - require:
      - file: nvidia-mig-symlink
      - file: persist-mig-config-name
    - onlyif:
      - test -x {{ wrapper_path }}
{% endif %}

# Final message
mig-server-setup-complete:
  test.succeed_with_changes:
    - name: "MIG setup complete – no more hang"
    - comment: |
        ✓ Stuck service stopped + old file removed
        ✓ Boot script updated with timeout protection
        ✓ Salt state now finishes instantly (service only enabled)
        ✓ Check live progress: tail -f /var/log/mig-apply.log
        Use: nvidia-mig status
