#!/usr/bin/env bats
# Unit tests for ansible-lint.sh - the composite action's helper that
# lints Ansible content. The most important contract is the auto-skip
# branch when no Ansible content exists (covered without a venv so it
# stays green on any workstation); pass/fail outcomes and config-
# discovery are covered against the controller venv's ansible-lint so
# the bar matches what consumers actually experience. The venv-
# dependent tests `skip` cleanly when the venv is not bootstrapped so
# the suite remains usable without it.
#
# The three docker-build retry cases from the old Common-Automation
# composite are deliberately NOT ported: the retried artifact (the
# in-repo docker image build) no longer exists under the venv model.

SCRIPT="${BATS_TEST_DIRNAME}/ansible-lint.sh"

# Controller venv bin/ dir. The action tree lives at
# .github/actions/ansible-lint/, so three levels up is the repo root
# where _bootstrap-controller-wsl.sh creates .venv/.
VENV_BIN="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)/.venv/bin"

setup() {
    # Run each case from an isolated workdir so the fixture trees
    # cannot leak across tests and so the target-dir detection in the
    # script sees only what the test created.
    workdir="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${workdir}"
}

require_ansible_lint() {
    # Mirror of the old composite's require_docker guard: skip the
    # cases that actually exercise ansible-lint when the controller
    # venv is not present, and otherwise put its bin/ on PATH so the
    # helper's bare `ansible-lint` resolves - the same contract the
    # workflow and local runner honour by activating the venv first.
    if [[ ! -x "${VENV_BIN}/ansible-lint" ]]; then
        skip "controller venv not bootstrapped (${VENV_BIN}/ansible-lint absent)"
    fi
    PATH="${VENV_BIN}:${PATH}"
}

@test "auto-skips when no Ansible content exists" {
    # Pre-venv-resolution branch - no ansible-lint required, so this
    # test locks the no-op contract even on bare workstations. An empty
    # workdir trivially has none of ansible.cfg/playbooks/roles.
    run bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"skipping"* ]]
}

@test "auto-skips when only unrelated YAML is present" {
    # A repo with arbitrary YAML but no Ansible markers must still
    # auto-skip - the detection key is structural (ansible.cfg /
    # playbooks/ / roles/), not "any YAML".
    printf 'greeting: hello\n' > "${workdir}/data.yml"
    run bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"skipping"* ]]
}

@test "exits 0 on a minimal valid playbook" {
    require_ansible_lint
    # Minimal playbook that satisfies the `production` profile:
    # explicit names, fqcn module, no-changed-when handled because
    # debug does not change state.
    mkdir -p "${workdir}/playbooks"
    cat > "${workdir}/playbooks/site.yml" <<'YAML'
---
- name: Smoke test play
  hosts: localhost
  gather_facts: false
  tasks:
    - name: Print a message
      ansible.builtin.debug:
        msg: hello
YAML
    run bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -eq 0 ]
}

@test "exits non-zero on a playbook with a known violation" {
    require_ansible_lint
    # `command` module with no changed_when is a stable violation on
    # the production profile (no-changed-when + command-instead-of-
    # module), so the run must fail.
    mkdir -p "${workdir}/playbooks"
    cat > "${workdir}/playbooks/bad.yml" <<'YAML'
---
- name: Bad play
  hosts: localhost
  gather_facts: false
  tasks:
    - name: Run a raw command
      ansible.builtin.command: /bin/true
YAML
    run bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -ne 0 ]
}

@test "honours a consumer-supplied .ansible-lint config" {
    require_ansible_lint
    # Same bad playbook as above, but a consumer config downgrades the
    # production profile to `min`, which does not enforce
    # command-instead-of-module or no-changed-when. If the consumer
    # config is read the run passes; if the bundled production default
    # is used instead it fails. This proves the discovery path, not
    # ansible-lint internals.
    mkdir -p "${workdir}/playbooks"
    cat > "${workdir}/playbooks/bad.yml" <<'YAML'
---
- name: Bad play
  hosts: localhost
  gather_facts: false
  tasks:
    - name: Run a raw command
      ansible.builtin.command: /bin/true
YAML
    cat > "${workdir}/.ansible-lint" <<'YAML'
profile: min
YAML
    run bash -c "cd '${workdir}' && '${SCRIPT}'"
    [ "${status}" -eq 0 ]
}
