#!/usr/bin/env bash
# Validates the optional `toolchains` block in the per-VM provisioner
# config against the three-section acquisition taxonomy this feature
# introduces (see the plan's "three-section tooling taxonomy"): every
# tool a VM needs is classified by how it is acquired -
#   hostPushed   - section 1, heavy artifacts the host caches and pushes
#                  (JDK, .NET SDK).
#   vmDownloaded - section 2, small packages the VM fetches itself
#                  (shellcheck, bats).
#   baseImage    - section 3, daemons installed at a coarser grain
#                  (Docker).
#
# This validator owns only the *outer taxonomy shape* - that the block is
# an object, that it names none but the three known sections, and that
# each present section is a list. It deliberately does not look inside a
# section's entries: each toolchain role validates its own slice (e.g.
# toolchain_apt asserts every entry names a package), so entry rules stay
# with the role that consumes them. The split keeps the substrate owning
# the taxonomy contract and the roles owning their payload.
#
# The taxonomy layer is the only place a malformed *section* can be caught
# with a clear message: by the time a consumer playbook has dispatched
# each section into a role var, the section boundary (and an unknown
# section key) is gone. So the check lives here, at the point the config
# is surfaced, and fails fast before a bad block reaches any role.
#
# Sourced (not exec'd) so a failure exits the calling extra-vars helper
# (mirroring _validate-extra-vars-input.sh). The config is assumed to be
# valid JSON already - the caller runs `_validate_extra_vars_input` first;
# this validator only reasons about structure.

# shellcheck source=ops/imports/_log.sh
source "${BASH_SOURCE[0]%/*}/../imports/_log.sh"

_validate_toolchains_config() {
    local path="$1"
    local errors

    # jq collects every taxonomy violation across all VM definitions and
    # streams one message per line (empty output == valid). The config is
    # normalised to an array first so a single-object document validates
    # the same as the canonical array form.
    errors="$(jq -r '
      (if type == "array" then . else [.] end)
      | [ .[]
          | select(type == "object" and has("toolchains"))
          | (.vmName // "(unknown)") as $name
          | .toolchains as $tc
          | if ($tc | type) != "object" then
              "VM \($name): toolchains must be an object, got \($tc | type)"
            else
              ( ($tc | keys_unsorted)
                  - ["hostPushed", "vmDownloaded", "baseImage"] ) as $unknown
              | ( if ($unknown | length) > 0 then
                    "VM \($name): unknown toolchains section(s): "
                    + ($unknown | join(", "))
                    + "; allowed: hostPushed, vmDownloaded, baseImage"
                  else empty end ),
                ( $tc | to_entries[]
                  | select(.value | type != "array")
                  | "VM \($name): toolchains.\(.key) must be a list, "
                    + "got \(.value | type)" )
            end
        ]
      | .[]
    ' "${path}")"

    if [[ -n "${errors}" ]]; then
        # Report every violation, one per line, so a config with several
        # bad sections is fixed in one pass rather than one error at a time.
        while IFS= read -r line; do
            [[ -n "${line}" ]] && log_err "${line}"
        done <<< "${errors}"
        exit 1
    fi
}
