#!/usr/bin/env bash
# Per-domain extra-vars helper: inventory.
#
# Emits the single top-level key `vm_provisioner_config` consumed by
# the playbooks and by _build-inventory.sh upstream. The inventory
# source is cross-cutting - every payload domain (users, runners,
# future toolchain) needs it - so it lives in its own helper rather
# than being folded into any one domain.
#
# Because this fragment is ALWAYS emitted (unlike per-vault fragments, which
# fire only when their vault is declared), it also carries the host file
# server URL when the bridge started one. host_file_server_base_url is a
# property of the file server, not of any vault, so a flow that stages the
# file server without declaring an extra vault (e.g. toolchains, whose
# desired-state now lives in the inventory vault) still reaches its roles with
# a base URL. The composer forwards the file-server pair here when present.
#
# Output (stdout): {"vm_provisioner_config": <document>}
#   plus {"host_file_server_base_url": <url>} when --host-base-url is given.

set -euo pipefail

# shellcheck source=ops/_validate-extra-vars-input.sh
source "${BASH_SOURCE[0]%/*}/../_validate-extra-vars-input.sh"
# shellcheck source=ops/_die-on-unknown-flag.sh
source "${BASH_SOURCE[0]%/*}/../_die-on-unknown-flag.sh"
# shellcheck source=ops/virtual-machines/_validate-toolchains-config.sh
source "${BASH_SOURCE[0]%/*}/_validate-toolchains-config.sh"

provisioner_path=""
host_base_url=""
host_base_url_set=0

usage() {
    echo "usage: _build-extra-vars-inventory.sh --provisioner-config <path>" \
         "[--host-base-url <url>] [--runner-version <ver>]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --provisioner-config)
            provisioner_path="${2:-}"
            shift 2 || true
            ;;
        --host-base-url)
            # ${2-} (no colon) so a literal empty value reaches the non-empty
            # check below rather than being dropped by the default branch.
            host_base_url="${2-}"
            host_base_url_set=1
            shift 2 || true
            ;;
        --runner-version)
            # Forwarded by the composer as the other half of the file-server
            # pair. This fragment only needs the base URL; the version is
            # consumed and discarded rather than rejected as unknown.
            shift 2 || true
            ;;
        *)
            _die_on_unknown_flag "$1"
            ;;
    esac
done

if [[ -z "${provisioner_path}" ]]; then
    usage
    exit 2
fi

if [[ "${host_base_url_set}" -eq 1 && -z "${host_base_url}" ]]; then
    echo "--host-base-url requires a non-empty value" >&2
    exit 2
fi

_validate_extra_vars_input --provisioner-config "${provisioner_path}"

# The config is surfaced whole under vm_provisioner_config, so the optional
# `toolchains` taxonomy block rides along untouched. Validate its outer
# shape here - at the surfacing point - so a malformed section fails with a
# clear message before it reaches a consumer playbook (which dispatches each
# section into a role var, past where the section boundary is still visible).
# Entry-level rules stay with the roles that consume each section.
_validate_toolchains_config "${provisioner_path}"

# --slurpfile loads the document as a one-element array; `$p[0]`
# extracts the document so it nests directly under the canonical key. When the
# bridge supplied a file-server URL, add host_file_server_base_url as a second
# disjoint top-level key so the downstream `jq -s add` merge keeps both.
if [[ "${host_base_url_set}" -eq 1 ]]; then
    jq -n --slurpfile p "${provisioner_path}" --arg u "${host_base_url}" \
        '{vm_provisioner_config: $p[0], host_file_server_base_url: $u}'
else
    jq -n --slurpfile p "${provisioner_path}" '{vm_provisioner_config: $p[0]}'
fi
