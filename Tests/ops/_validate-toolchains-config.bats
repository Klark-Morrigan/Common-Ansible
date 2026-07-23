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
    printf '%s' '[{"vmName":"a","toolchains":{"hostPushed":[],"vmDownloaded":{"apt":[{"name":"shellcheck"}]},"baseImage":[]}}]' > "${CFG}"
    _run_validate
    [ "${status}" -eq 0 ]
}

@test "passes on a partial block (only some sections present)" {
    printf '%s' '[{"vmName":"a","toolchains":{"vmDownloaded":{"apt":[{"name":"bats"}]}}}]' > "${CFG}"
    _run_validate
    [ "${status}" -eq 0 ]
}

@test "passes with both vmDownloaded mechanisms present" {
    printf '%s' '[{"vmName":"a","toolchains":{"vmDownloaded":{"apt":[{"name":"bats"}],"batsLibs":[{"name":"bats-support","version":"0.3.0"}]}}}]' > "${CFG}"
    _run_validate
    [ "${status}" -eq 0 ]
}

@test "passes when vmDownloaded carries only batsLibs" {
    printf '%s' '[{"vmName":"a","toolchains":{"vmDownloaded":{"batsLibs":[{"name":"bats-assert","version":"2.1.0"}]}}}]' > "${CFG}"
    _run_validate
    [ "${status}" -eq 0 ]
}

@test "does not inspect section entries (that is the role's slice)" {
    # An entry with no 'name' is a role-level violation (toolchain_apt /
    # toolchain_bats_libs assert it), not a taxonomy one - this validator
    # must let it pass.
    printf '%s' '[{"vmName":"a","toolchains":{"vmDownloaded":{"apt":[{"version":"1"}]}}}]' > "${CFG}"
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

@test "rejects hostPushed that is not a list" {
    printf '%s' '[{"vmName":"b","toolchains":{"hostPushed":{"name":"x"}}}]' > "${CFG}"
    _run_validate
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"VM b: toolchains.hostPushed must be a list, got object"* ]]
}

@test "rejects vmDownloaded that is not an object" {
    # The old list shape is now invalid: vmDownloaded is a per-mechanism
    # object, so a bare list must fail with a shape-specific message.
    printf '%s' '[{"vmName":"b","toolchains":{"vmDownloaded":[{"name":"x"}]}}]' > "${CFG}"
    _run_validate
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"VM b: toolchains.vmDownloaded must be an object with apt / batsLibs lists, got array"* ]]
}

@test "rejects an unknown vmDownloaded mechanism with a clear message" {
    printf '%s' '[{"vmName":"c","toolchains":{"vmDownloaded":{"apt":[],"typo":[]}}}]' > "${CFG}"
    _run_validate
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"VM c: unknown vmDownloaded mechanism(s): typo"* ]]
    [[ "${output}" == *"allowed: apt, batsLibs"* ]]
}

@test "rejects a vmDownloaded mechanism that is not a list" {
    printf '%s' '[{"vmName":"d","toolchains":{"vmDownloaded":{"batsLibs":{"name":"x"}}}}]' > "${CFG}"
    _run_validate
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"VM d: toolchains.vmDownloaded.batsLibs must be a list, got object"* ]]
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
