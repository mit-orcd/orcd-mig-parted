# ===================================================================
# Optional: deploy wrapper + config from the Salt fileserver.
# Include from init.sls after mig-parted-directory exists:
#
#   include:
#     - .deploy-repo
#
# Place this repo (or a subset) under the fileserver, e.g.:
#   salt://engaging/role/mig-server/files/nvidia-mig
#   salt://engaging/role/mig-server/files/db/config.yaml
#
# Mirror paths from the orcd-mig-parted git repo into that tree via CI
# or gitfs — do not maintain a second copy by hand.
# ===================================================================

{% set mig_dir = "/home/systems/mig/mig-parted" %}
{% set wrapper_path = mig_dir ~ "/nvidia-mig" %}
{% set config_path = mig_dir ~ "/db/config.yaml" %}

deploy-nvidia-mig-wrapper:
  file.managed:
    - name: {{ wrapper_path }}
    - source: salt://engaging/role/mig-server/files/nvidia-mig
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - file: mig-parted-directory

deploy-mig-config-yaml:
  file.managed:
    - name: {{ config_path }}
    - source: salt://engaging/role/mig-server/files/db/config.yaml
    - user: root
    - group: root
    - mode: '0644'
    - makedirs: True
    - require:
      - file: mig-parted-directory

# Upstream binary is not in git (license/build). Install via package, artifact, or:
#
# deploy-nvidia-mig-parted-binary:
#   file.managed:
#     - name: {{ mig_dir }}/nvidia-mig-parted
#     - source: salt://engaging/role/mig-server/files/nvidia-mig-parted
#     - mode: '0755'
