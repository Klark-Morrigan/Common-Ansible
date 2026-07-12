#!/usr/bin/env bash
# Runs ansible-lint over a target repo's Ansible content (playbooks,
# roles, ansible.cfg). Auto-skips with a `::notice::` when none of
# `ansible.cfg`, `playbooks/`, or `roles/` exists at the target root -
# the composite is wired into every consumer's ci-ansible.yml job so it
# must no-op silently on repos with no Ansible content rather than fail
# or print noise.
#
# Single source of truth for the ansible-lint invocation - the
# composite wrapper (action.yml) and the local pre-push runner
# (scripts/run-lint-ansible.sh) both exec this file so the detection
# rules and config resolution cannot drift between CI and local.
#
# Execution model: ansible-lint is invoked directly from PATH. The
# caller (the ci-ansible.yml job, or the local runner) is responsible
# for putting the controller venv's bin/ on PATH first, so the exact
# pinned ansible-lint/ansible-core closure from requirements.txt runs -
# there is no docker image, no version getter, and no per-run pip
# install here (all three lived in the old Common-Automation composite
# and are deliberately gone with the venv move).
#
# Config resolution: a consumer-supplied .ansible-lint /
# .ansible-lint.yml / .ansible-lint.yaml at the target root wins
# (ansible-lint auto-discovers it from the working directory).
# Otherwise the bundled ansible-lint.config.yml next to this script
# applies via -c - the `production` profile, so every consumer gets
# the strictest built-in bar by default.
#
# Usage: ./ansible-lint.sh [target-dir]   (target-dir defaults to $PWD)

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the target to an absolute path and run from inside it. Working
# from the target root (rather than relying on the caller's cwd) keeps
# both the structural detection below and ansible-lint's own cwd-based
# config auto-discovery deterministic no matter where the helper is
# invoked - the composite runs it from the action dir, the local runner
# from the repo root.
target_dir="$(cd "${1:-${PWD}}" && pwd)"
cd "${target_dir}"

# Auto-skip detection. Mirrors the old composite's contract: the job
# runs unconditionally, so a repo with no Ansible content must no-op
# rather than fail. ansible-lint with no playbooks/roles still emits
# warnings about missing inventory - the auto-skip keeps non-Ansible
# runs quiet.
if [[ ! -f ansible.cfg && ! -d playbooks && ! -d roles ]]; then
    echo "::notice::no Ansible content (ansible.cfg/playbooks/roles), skipping"
    exit 0
fi

# Consumer-config wins so a downstream repo can tighten or relax the
# bar. ansible-lint auto-discovers these names from the working
# directory when -c is omitted; we detect explicitly here so the
# bundled-config branch is observable and only passes -c for the
# bundled default.
consumer_config=""
for candidate in .ansible-lint .ansible-lint.yml .ansible-lint.yaml; do
    if [[ -f "${candidate}" ]]; then
        consumer_config="${candidate}"
        break
    fi
done

config_args=()
if [[ -z "${consumer_config}" ]]; then
    config_args=(-c "${script_dir}/ansible-lint.config.yml")
fi

# --project-dir is explicit because passing -c <path> would otherwise
# set project_dir to the config file's directory (i.e. the action dir),
# causing ansible-lint to scan the bundled config instead of the target
# repo. --force-color keeps output readable in CI logs where ansible-
# lint defaults to colourless.
ansible-lint --force-color --project-dir "${target_dir}" "${config_args[@]}"
