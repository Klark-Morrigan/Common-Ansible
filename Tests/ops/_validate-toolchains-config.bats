#!/usr/bin/env bats
# Tests for ops/virtual-machines/_validate-toolchains-config.sh - the
# taxonomy-shape validator for the optional `toolchains` block in the
# per-VM provisioner config. Sourced (not exec'd) in production, so each
# case runs it as `source <script>; _validate_toolchains_config <path>`
# in a subshell and inspects the exit status + stderr. jq is the only
# external dep, run for real.
# Run with: bats Tests/ops/_validate-toolchains-config.bats

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../ops/virtual-machines" && pwd)/_validate-toolchains-config.sh"

# shellcheck source=Tests/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

setup() {
    _bats_init_temp validateToolchains
    CFG="${TEST_TMP}/config.json"
}

teardown() {
    _bats_cleanup_temp
}

# Invoke the sourced validator in a subshell so an `exit 1` inside it does
# not abort the bats run, and so stderr is captured for the message check.
_run_validate() {
    run "${BASH_BIN}" -c "source '${SCRIPT}'; _validate_toolchains_config '${CFG}'"
}

@test "passes when no VM declares a toolchains block" {
    printf '%s' '[{"vmName":"a","ipAddress":"10.0.0.1"}]' > "${CFG}"
    _run_validate
    [ "${status}" -eq 0 ]
}

@test "passes on a full, well-formed three-section block" {
    printf '%s' '[{"vmName":"a","toolchains":{"hostPushed":[],"vmDownloaded":[{"name":"shellcheck"}],"baseImage":[]}}]' > "${CFG}"
    _run_validate
    [ "${status}" -eq 0 ]
}

@test "passes on a partial block (only some sections present)" {
    printf '%s' '[{"vmName":"a","toolchains":{"vmDownloaded":[{"name":"bats"}]}}]' > "${CFG}"
    _run_validate
    [ "${status}" -eq 0 ]
}

@test "does not inspect section entries (that is the role's slice)" {
    # An entry with no 'name' is a role-level violation (toolchain_apt
    # asserts it), not a taxonomy one - this validator must let it pass.
    printf '%s' '[{"vmName":"a","toolchains":{"vmDownloaded":[{"version":"1"}]}}]' > "${CFG}"
    _run_validate
    [ "${status}" -eq 0 ]
}

@test "rejects an unknown section with a clear, named message" {
    printf '%s' '[{"vmName":"a","toolchains":{"hostPushed":[],"typo":[]}}]' > "${CFG}"
    _run_validate
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"VM a"* ]]
    [[ "${output}" == *"unknown toolchains section(s): typo"* ]]
    [[ "${output}" == *"allowed: hostPushed, vmDownloaded, baseImage"* ]]
}

@test "rejects a section that is not a list" {
    printf '%s' '[{"vmName":"b","toolchains":{"vmDownloaded":{"name":"x"}}}]' > "${CFG}"
    _run_validate
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"VM b: toolchains.vmDownloaded must be a list, got object"* ]]
}

@test "rejects a toolchains value that is not an object" {
    printf '%s' '[{"vmName":"c","toolchains":["x"]}]' > "${CFG}"
    _run_validate
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"VM c: toolchains must be an object, got array"* ]]
}

@test "names an unnamed VM as (unknown) rather than crashing" {
    printf '%s' '[{"toolchains":{"baseImage":"nope"}}]' > "${CFG}"
    _run_validate
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"VM (unknown): toolchains.baseImage must be a list, got string"* ]]
}

@test "reports every violation across VMs in one pass" {
    printf '%s' '[{"vmName":"a","toolchains":{"typo":[]}},{"vmName":"b","toolchains":{"baseImage":"x"}}]' > "${CFG}"
    _run_validate
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"VM a: unknown toolchains section(s): typo"* ]]
    [[ "${output}" == *"VM b: toolchains.baseImage must be a list"* ]]
}

@test "validates a single-object document the same as the array form" {
    printf '%s' '{"vmName":"solo","toolchains":{"typo":[]}}' > "${CFG}"
    _run_validate
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"VM solo: unknown toolchains section(s): typo"* ]]
}
