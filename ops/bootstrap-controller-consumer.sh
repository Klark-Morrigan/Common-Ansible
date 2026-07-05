#!/usr/bin/env bash
# SSOT for consumer-side Ansible controller bootstrap. Runs inside WSL.
#
# Every repo that consumes the Common-Ansible substrate needs the same thin
# bootstrap: locate the substrate, make sure the shared controller (the venv +
# ansible-core + substrate collections that this repo's own
# bootstrap-controller.ps1 builds) exists, and reuse it rather than forking it.
# That logic used to be copy-pasted into each consumer's
# ops/bootstrap-controller.sh; it lives here once instead. Each consumer keeps
# only a ~4-line shim that resolves the sibling and execs this with its own
# Ansible-slice root:
#
#   exec "${common_ansible_root}/ops/bootstrap-controller-consumer.sh" "${ansible_root}"
#
# There is nothing substrate-specific to install for a consumer: its roles (if
# any) live in its own roles/ and resolve at play time - the flow wrappers
# declare CA_CONSUMER_ROOT and the bridge puts the consumer's roles/ ahead of
# the substrate's on ANSIBLE_ROLES_PATH (see each consumer's README). A
# consumer with no roles/ (e.g. a flow that only composes substrate roles)
# resolves roles from the substrate alone.
set -euo pipefail

# The consumer's Ansible-slice root (…/hyper-v/ubuntu/Ansible), used only for
# the roles-path summary below. Required so the message is honest about which
# tree ANSIBLE_ROLES_PATH prefers.
consumer_ansible_root="${1:?usage: bootstrap-controller-consumer.sh <consumer-ansible-root>}"

# The substrate root is this script's own parent (ops/ -> repo root).
# COMMON_ANSIBLE_ROOT overrides it for tests / non-standard layouts, matching
# the consumers' own _common-ansible-root.sh resolver.
if [[ -n "${COMMON_ANSIBLE_ROOT:-}" ]]; then
    common_ansible_root="${COMMON_ANSIBLE_ROOT}"
else
    common_ansible_root="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
fi

venv_python="${common_ansible_root}/.venv/bin/python"

# Ensure the shared controller exists. When the substrate venv is absent,
# delegate to the substrate's own public bootstrap rather than rebuilding the
# venv here - that script owns the WSL2/bash gates, venv creation, and the
# substrate collection pins. It is a Windows entry point, so reach it through
# pwsh.exe (already a hard controller dependency) with a Windows path from
# wslpath.
if [[ ! -x "${venv_python}" ]]; then
    echo "Substrate controller venv not found at ${common_ansible_root}/.venv" >&2
    echo "Bootstrapping the shared Common-Ansible controller first ..." >&2
    substrate_bootstrap_win="$(wslpath -w "${common_ansible_root}/ops/bootstrap-controller.ps1")"
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "${substrate_bootstrap_win}"
fi

if [[ ! -x "${venv_python}" ]]; then
    echo "Controller bootstrap did not produce ${venv_python}." >&2
    echo "Bootstrap the Common-Ansible substrate manually, then re-run." >&2
    exit 1
fi

echo ""
echo "Consumer controller bootstrap complete:"
echo "  Substrate sibling : ${common_ansible_root}"
echo "  Controller venv   : ${common_ansible_root}/.venv"
# A consumer that ships its own roles/ gets them ahead of the substrate's on
# ANSIBLE_ROLES_PATH; a substrate-only consumer resolves from the substrate.
if [[ -d "${consumer_ansible_root}/roles" ]]; then
    echo "  Roles resolve via : ANSIBLE_ROLES_PATH -> ${consumer_ansible_root}/roles then ${common_ansible_root}/roles"
else
    echo "  Roles resolve via : ANSIBLE_ROLES_PATH -> ${common_ansible_root}/roles (substrate-only)"
fi
