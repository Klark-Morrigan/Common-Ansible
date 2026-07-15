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

# Anchor to this script's own dir. dirname (not ${BASH_SOURCE%/*}) so it
# resolves whether $0 arrives with POSIX slashes (WSL / the re-exec below) or
# a Windows argv[0] (a Git Bash launch, where %/* would strip nothing).
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The consumer's Ansible-slice root (.../hyper-v/ubuntu/Ansible), used only for
# the roles-path summary below. Required so the message is honest about which
# tree ANSIBLE_ROLES_PATH prefers. Captured before the launcher bridge so it
# can be path-translated into the WSL re-exec.
consumer_ansible_root="${1:?usage: bootstrap-controller-consumer.sh <consumer-ansible-root>}"

# ---------------------------------------------------------------------------
# Windows launcher bridge (mirror of ops/_run-playbook.sh). This bootstrap
# does its work inside the WSL controller: it probes the Linux venv
# (.venv/bin/python is a Linux symlink) and, when the venv is absent, reaches
# the substrate's Windows bootstrap through wslpath + pwsh.exe - neither of
# which exists under Git Bash. But the operator entry points (each consumer's
# thin bootstrap-controller.sh shim, launched by the menu's Invoke-BashScript)
# run under Git Bash. So on a Git Bash / Cygwin launch, re-exec self inside the
# WSL default distro - the same distro bootstrap-controller provisions and
# drives via `wsl --`. uname -s is "Linux" inside WSL and on native-Linux CI,
# so the re-exec fires exactly once and never on the controller itself (no
# loop, no effect on the bats suite, which runs under Linux).
# ---------------------------------------------------------------------------
case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
        if ! command -v wsl.exe >/dev/null 2>&1; then
            echo "launched under Git Bash but wsl.exe is not available; this bootstrap runs in the WSL controller. Install WSL and run ops/bootstrap-controller first." >&2
            exit 2
        fi
        # Translate /c/... (Git Bash) -> /mnt/c/... (WSL mount) for both this
        # script's own path and its positional arg (a wrapper resolved the
        # consumer root as a /c/... path the WSL side cannot open). \L
        # lowercases the drive letter (GNU sed, which Git Bash ships).
        wsl_self="$(printf '%s' "${script_dir}" | sed -E 's#^/([A-Za-z])/#/mnt/\L\1/#')/bootstrap-controller-consumer.sh"
        consumer_root_wsl="$(printf '%s' "${consumer_ansible_root}" | sed -E 's#^/([A-Za-z])/#/mnt/\L\1/#')"
        # COMMON_ANSIBLE_ROOT (test / non-standard-layout override) may also be
        # a /c/... path; translate it and forward via WSLENV so the WSL side's
        # resolver honours it. Empty/unset forwards harmlessly.
        if [[ -n "${COMMON_ANSIBLE_ROOT:-}" ]]; then
            COMMON_ANSIBLE_ROOT="$(printf '%s' "${COMMON_ANSIBLE_ROOT}" | sed -E 's#^/([A-Za-z])/#/mnt/\L\1/#')"
            export COMMON_ANSIBLE_ROOT
            export WSLENV="${WSLENV:+${WSLENV}:}COMMON_ANSIBLE_ROOT"
        fi
        # MSYS2 rewrites /-leading args into Windows paths when launching a
        # Windows .exe, which corrupts the /mnt path; disable it for this exec.
        export MSYS2_ARG_CONV_EXCL='*'
        export MSYS_NO_PATHCONV=1
        echo "Git Bash launch detected; re-executing under the WSL controller (default distro) ..." >&2
        exec wsl.exe -- bash "${wsl_self}" "${consumer_root_wsl}"
        ;;
    *)
        # WSL ("Linux" uname) or native-Linux CI: the wslpath / pwsh.exe / venv
        # toolchain is reachable, so run in place. This is where the re-exec
        # above lands and the path the bats suite takes.
        ;;
esac

# The substrate root is this script's own parent (ops/ -> repo root).
# COMMON_ANSIBLE_ROOT overrides it for tests / non-standard layouts, matching
# the consumers' own _common-ansible-root.sh resolver.
if [[ -n "${COMMON_ANSIBLE_ROOT:-}" ]]; then
    common_ansible_root="${COMMON_ANSIBLE_ROOT}"
else
    common_ansible_root="$(cd "${script_dir}/.." && pwd)"
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
