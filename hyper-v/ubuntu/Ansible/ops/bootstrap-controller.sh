#!/usr/bin/env bash
# Thin consumer bootstrap shim for Infrastructure-Vm-Users. Runs inside WSL.
#
# The bootstrap logic is a SSOT in the Common-Ansible substrate
# (ops/bootstrap-controller-consumer.sh), reached through the sibling checkout;
# this shim only resolves the substrate and hands it this repo's Ansible-slice
# root (for the roles-path summary). Kept per-repo so `bootstrap-controller
# (Ansible)` is a uniform menu entry across the substrate consumers.
set -euo pipefail

# dirname (not ${BASH_SOURCE%/*}) so this resolves whether $0 arrives with
# POSIX slashes (WSL) or backslashes (the menu invokes it via Git Bash with
# a Windows Join-Path argv[0]); the %/* string-strip only knows '/' and would
# leave the whole path, cd-ing into the script file itself.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ansible_root="$(cd "${script_dir}/.." && pwd)"

# Locate the substrate sibling (override with COMMON_ANSIBLE_ROOT).
# shellcheck source=hyper-v/ubuntu/Ansible/ops/imports/_common-ansible-root.sh
source "${script_dir}/imports/_common-ansible-root.sh"

exec "${common_ansible_root}/ops/bootstrap-controller-consumer.sh" "${ansible_root}"
