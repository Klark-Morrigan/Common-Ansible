#!/usr/bin/env bats
# Tests for ops/bootstrap-controller-consumer.sh - the SSOT consumer-side
# controller bootstrap that every substrate consumer's thin
# bootstrap-controller.sh shim execs.
#
# Strategy: point the script at a FAKE substrate root via COMMON_ANSIBLE_ROOT
# (so it never touches the developer's real .venv), and prepend a stubs dir to
# PATH so `pwsh.exe` and `wslpath` are intercepted. The consumer-root arg is a
# throwaway temp dir the test creates with or without a roles/ subdir to
# exercise the two roles-path summary branches.
# Run with: bats Tests/ops/bootstrap-controller-consumer.bats

bats_require_minimum_version 1.5.0

SCRIPT="$(cd "${BATS_TEST_DIRNAME}/../../ops" && pwd)/bootstrap-controller-consumer.sh"

# shellcheck source=Tests/ops/_bats-helpers.sh
source "${BATS_TEST_DIRNAME}/_bats-helpers.sh"

setup() {
    _bats_init_temp bootstrapConsumer

    # Fake substrate root the script treats as common_ansible_root. A .venv is
    # added per-test when the "already bootstrapped" path is under test.
    FAKE_CA="${TEST_TMP}/common-ansible"
    mkdir -p "${FAKE_CA}/ops"
    # wslpath -w needs the target to exist, so drop a placeholder ps1.
    printf '# placeholder\n' > "${FAKE_CA}/ops/bootstrap-controller.ps1"

    # Consumer Ansible-slice roots: one substrate-only, one shipping roles/.
    CONSUMER_NO_ROLES="${TEST_TMP}/consumer-plain"
    CONSUMER_WITH_ROLES="${TEST_TMP}/consumer-roles"
    mkdir -p "${CONSUMER_NO_ROLES}"
    mkdir -p "${CONSUMER_WITH_ROLES}/roles"

    STUBS="${TEST_TMP}/stubs"
    mkdir -p "${STUBS}"

    # wslpath stub: echo a plausible Windows path so the delegate branch does
    # not depend on real WSL interop (keeps the suite green under the docker
    # bats fallback too).
    cat >"${STUBS}/wslpath" <<WSLP
#!${BASH_BIN}
echo 'C:\\fake\\bootstrap-controller.ps1'
WSLP
    chmod +x "${STUBS}/wslpath"

    MARKER="${TEST_TMP}/pwsh-was-called"
}

teardown() {
    _bats_cleanup_temp
}

# seed_venv - materialise a fake, executable venv python under the substrate
# so the script takes the "already bootstrapped" branch.
seed_venv() {
    mkdir -p "${FAKE_CA}/.venv/bin"
    printf '#!%s\nexit 0\n' "${BASH_BIN}" > "${FAKE_CA}/.venv/bin/python"
    chmod +x "${FAKE_CA}/.venv/bin/python"
}

# seed_pwsh <create-venv?> - drop a pwsh.exe stub. It always records that it
# ran (MARKER); when the arg is "create" it also materialises the venv python,
# simulating a successful substrate bootstrap.
seed_pwsh() {
    local create="${1:-}"
    {
        printf '#!%s\n' "${BASH_BIN}"
        printf 'touch %q\n' "${MARKER}"
        if [[ "${create}" == "create" ]]; then
            printf 'mkdir -p %q\n' "${FAKE_CA}/.venv/bin"
            printf 'printf "#!%s\\nexit 0\\n" > %q\n' "${BASH_BIN}" "${FAKE_CA}/.venv/bin/python"
            printf 'chmod +x %q\n' "${FAKE_CA}/.venv/bin/python"
        fi
        printf 'exit 0\n'
    } > "${STUBS}/pwsh.exe"
    chmod +x "${STUBS}/pwsh.exe"
}

run_consumer() {
    local consumer_root="$1"
    run env "PATH=${STUBS}:${PATH}" "COMMON_ANSIBLE_ROOT=${FAKE_CA}" \
        "${BASH_BIN}" "${SCRIPT}" "${consumer_root}"
}

@test "requires the consumer ansible-root arg" {
    run env "PATH=${STUBS}:${PATH}" "COMMON_ANSIBLE_ROOT=${FAKE_CA}" \
        "${BASH_BIN}" "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"usage:"* ]]
}

@test "venv present: prints the summary and does NOT delegate to pwsh" {
    seed_venv
    seed_pwsh   # would run if the script wrongly delegated
    run_consumer "${CONSUMER_NO_ROLES}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Consumer controller bootstrap complete"* ]]
    [ ! -f "${MARKER}" ]
}

@test "substrate-only consumer: roles line says substrate-only" {
    seed_venv
    run_consumer "${CONSUMER_NO_ROLES}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"(substrate-only)"* ]]
}

@test "consumer shipping roles/: roles line prefers the consumer roles" {
    seed_venv
    run_consumer "${CONSUMER_WITH_ROLES}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"${CONSUMER_WITH_ROLES}/roles then ${FAKE_CA}/roles"* ]]
}

@test "venv absent: delegates to pwsh, which provisions it, then succeeds" {
    seed_pwsh create
    run_consumer "${CONSUMER_NO_ROLES}"
    [ "${status}" -eq 0 ]
    [ -f "${MARKER}" ]
    [[ "${output}" == *"Bootstrapping the shared Common-Ansible controller first"* ]]
    [[ "${output}" == *"Consumer controller bootstrap complete"* ]]
}

@test "venv absent and bootstrap fails to produce it: exits 1 with a hint" {
    seed_pwsh   # runs but does NOT create the venv
    run_consumer "${CONSUMER_NO_ROLES}"
    [ "${status}" -eq 1 ]
    [ -f "${MARKER}" ]
    [[ "${output}" == *"did not produce"* ]]
    [[ "${output}" == *"Bootstrap the Common-Ansible substrate manually"* ]]
}

@test "Git Bash launch re-execs the consumer bootstrap under the WSL controller" {
    # The menu (Invoke-BashScript) launches each consumer's shim - and thus
    # this SSOT - under Git Bash, where wslpath / pwsh.exe / the Linux venv are
    # not usable. A MINGW/MSYS uname must re-exec self under `wsl --` rather
    # than run here (mirrors _run-playbook.sh's guard). Stub uname -> MINGW and
    # wsl.exe -> a recorder so the re-exec wiring is asserted without a real
    # WSL. The re-exec sits before the venv probe and any pwsh delegation, so
    # nothing local is touched.
    cat >"${STUBS}/uname" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "-s" ]]; then echo "MINGW64_NT-10.0-26200"; else exec /usr/bin/uname "$@"; fi
STUB
    cat >"${STUBS}/wsl.exe" <<STUB
#!${BASH_BIN}
printf '%s\n' "\$@" > "${TEST_TMP}/wsl-args"
exit 0
STUB
    chmod +x "${STUBS}/uname" "${STUBS}/wsl.exe"

    # No venv seeded and pwsh stub records if wrongly called: the re-exec must
    # fire before either is consulted.
    seed_pwsh
    run_consumer "${CONSUMER_NO_ROLES}"

    [ "${status}" -eq 0 ]
    # Re-exec fired: the recorder captured the bridge plus the translated
    # consumer-root arg.
    [ -f "${TEST_TMP}/wsl-args" ]
    grep -q 'bootstrap-controller-consumer.sh' "${TEST_TMP}/wsl-args"
    grep -q -- "${CONSUMER_NO_ROLES}"          "${TEST_TMP}/wsl-args"
    # And nothing ran in the Git Bash process - pwsh was never delegated to.
    [ ! -f "${MARKER}" ]
}
