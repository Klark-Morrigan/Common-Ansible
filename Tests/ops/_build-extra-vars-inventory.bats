#!/usr/bin/env bats
# Tests for ops/virtual-machines/_build-extra-vars-inventory.sh - per-domain helper
# emitting vm_provisioner_config. Pure transform; jq is the only
# external dep, run for real.
# Run with: bats Tests/ops/_build-extra-vars-inventory.bats

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../ops/virtual-machines" && pwd)/_build-extra-vars-inventory.sh"

# shellcheck source=Tests/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

setup() {
    _bats_init_temp buildExtraVarsInv
    PROV="${TEST_TMP}/provisioner.json"
}

teardown() {
    _bats_cleanup_temp
}

@test "fails with usage when --provisioner-config is missing" {
    run "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"usage:"* ]]
}

@test "fails with usage on unknown flag" {
    run "${BASH_BIN}" "${SCRIPT}" --unknown-thing x
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"unknown argument"* ]]
}

@test "fails with file path when the provisioner config is missing" {
    run "${BASH_BIN}" "${SCRIPT}" --provisioner-config "${TEST_TMP}/does-not-exist.json"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"provisioner-config"* ]]
    [[ "${output}" == *"not found"* ]]
}

@test "fails when the provisioner config is not valid JSON" {
    printf '%s' 'not-json' > "${PROV}"
    run "${BASH_BIN}" "${SCRIPT}" --provisioner-config "${PROV}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"provisioner-config"* ]]
    [[ "${output}" == *"not valid JSON"* ]]
}

@test "valid input emits a single-key object with vm_provisioner_config" {
    printf '%s' '[{"vmName":"a","ipAddress":"10.0.0.1"}]' > "${PROV}"
    run "${BASH_BIN}" "${SCRIPT}" --provisioner-config "${PROV}"
    [ "${status}" -eq 0 ]

    # Helper output is one object with exactly one key; the
    # orchestrator's job is to merge multiple such fragments.
    [ "$(printf '%s' "${output}" | jq -r 'keys | join(",")')" = "vm_provisioner_config" ]
    [ "$(printf '%s' "${output}" | jq -r '.vm_provisioner_config[0].vmName')" = "a" ]
    [ "$(printf '%s' "${output}" | jq -r '.vm_provisioner_config[0].ipAddress')" = "10.0.0.1" ]
}

@test "adds host_file_server_base_url as a second key when the file-server pair is given" {
    # The always-on inventory fragment carries the file-server URL so a flow
    # can stage the file server without declaring an extra vault. The runner
    # version is consumed and discarded (only the base URL is emitted).
    printf '%s' '[{"vmName":"a","ipAddress":"10.0.0.1"}]' > "${PROV}"
    run "${BASH_BIN}" "${SCRIPT}" --provisioner-config "${PROV}" \
        --host-base-url "http://10.10.0.1:8745" --runner-version "2.999.0"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r 'keys | sort | join(",")')" = "host_file_server_base_url,vm_provisioner_config" ]
    [ "$(printf '%s' "${output}" | jq -r '.host_file_server_base_url')" = "http://10.10.0.1:8745" ]
    [ "$(printf '%s' "${output}" | jq -r '.vm_provisioner_config[0].vmName')" = "a" ]
}

@test "omits host_file_server_base_url when no base url is given" {
    printf '%s' '[{"vmName":"a","ipAddress":"10.0.0.1"}]' > "${PROV}"
    run "${BASH_BIN}" "${SCRIPT}" --provisioner-config "${PROV}"
    [ "${status}" -eq 0 ]
    [ "$(printf '%s' "${output}" | jq -r 'has("host_file_server_base_url")')" = "false" ]
}

@test "rejects an empty --host-base-url value" {
    printf '%s' '[{"vmName":"a","ipAddress":"10.0.0.1"}]' > "${PROV}"
    run "${BASH_BIN}" "${SCRIPT}" --provisioner-config "${PROV}" --host-base-url ""
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"--host-base-url requires a non-empty value"* ]]
}

@test "a well-formed toolchains block rides through untouched" {
    printf '%s' '[{"vmName":"a","toolchains":{"vmDownloaded":[{"name":"shellcheck"}]}}]' > "${PROV}"
    run "${BASH_BIN}" "${SCRIPT}" --provisioner-config "${PROV}"
    [ "${status}" -eq 0 ]
    # Surfaced verbatim under the canonical key, ready for a consumer
    # playbook's per-section dispatch.
    [ "$(printf '%s' "${output}" | jq -r '.vm_provisioner_config[0].toolchains.vmDownloaded[0].name')" = "shellcheck" ]
}

@test "a malformed toolchains section fails the surfacing with a clear message" {
    printf '%s' '[{"vmName":"a","toolchains":{"typo":[]}}]' > "${PROV}"
    run "${BASH_BIN}" "${SCRIPT}" --provisioner-config "${PROV}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"VM a: unknown toolchains section(s): typo"* ]]
}
