#!/usr/bin/env bats
# Integration check for timing_tree.py: run a tiny gather_facts + role playbook
# under the callback and assert the per-task rows it writes match the
# timing_graft_children_from contract - role<TAB>name<TAB>elapsed_ms<TAB>status,
# with Gathering Facts roleless and the role's tasks attributed to it.
#
# Skips when the controller venv / ansible-playbook is absent (the bats CI image
# has no venv), so this only runs where a real ansible is available. Run locally:
#   bash wsl-task.sh bats Common-Ansible callback_plugins/timing_tree.bats

setup() {
    CB_DIR="${BATS_TEST_DIRNAME}"
    REPO_ROOT="$(cd "${CB_DIR}/.." && pwd)"
    VENV="${REPO_ROOT}/.venv"
    PY="${VENV}/bin/python"
    APB="${VENV}/bin/ansible-playbook"
    if [[ ! -x "${PY}" || ! -f "${APB}" ]]; then
        skip "controller venv / ansible-playbook not present"
    fi
    WORK="${BATS_TEST_TMPDIR}/play"
    mkdir -p "${WORK}/roles/toolchain_demo/tasks"
}

@test "timing_tree writes role-attributed per-task rows from a real run" {
    cat >"${WORK}/hosts.ini" <<'INV'
localhost ansible_connection=local
INV
    cat >"${WORK}/roles/toolchain_demo/tasks/main.yml" <<'TASKS'
---
- name: demo first task
  ansible.builtin.debug:
    msg: first
- name: demo second task
  ansible.builtin.command: "true"
  changed_when: false
TASKS
    cat >"${WORK}/play.yml" <<'PLAY'
---
- name: timing callback demo
  hosts: localhost
  gather_facts: true
  tasks:
    - name: import the demo role
      ansible.builtin.import_role:
        name: toolchain_demo
PLAY

    out="${WORK}/rows.tsv"
    export TIMING_TASKS_OUTPUT_PATH="${out}"
    export ANSIBLE_CALLBACK_PLUGINS="${CB_DIR}"
    export ANSIBLE_CALLBACKS_ENABLED="timing_tree"
    export ANSIBLE_ROLES_PATH="${WORK}/roles"

    run "${PY}" "${APB}" -i "${WORK}/hosts.ini" "${WORK}/play.yml"
    [ "${status}" -eq 0 ]
    # The rows file proves the callback loaded from the /mnt/c plugin dir (i.e.
    # Ansible did not refuse it as world-writable the way it does ansible.cfg).
    [ -f "${out}" ]

    # Roleless Gathering Facts row (blank role -> a leading tab).
    grep -qE "$(printf '^\tGathering Facts\t[0-9]+\tOK$')" "${out}"
    # Both role tasks attributed to the role, numeric ms, OK status.
    grep -qE "$(printf '^toolchain_demo\tdemo first task\t[0-9]+\tOK$')" "${out}"
    grep -qE "$(printf '^toolchain_demo\tdemo second task\t[0-9]+\tOK$')" "${out}"

    # End-to-end seam: feed the rows this real run produced through the bash
    # emitter's graft verb (the same call provision-toolchains.sh makes inside its
    # 'run playbook' span) and confirm the tree deepens - roleless Gathering Facts
    # as a leaf, the role's two tasks under a toolchain_demo node. This is the
    # proof the per-task data lands IN the timing report, not beside it.
    timing_sh="$(cd "${REPO_ROOT}/../Common-Automation/scripts" && pwd)/timing.sh"
    tree="${WORK}/tree.json"
    driver="${WORK}/flow.sh"
    {
        printf '#!/usr/bin/env bash\nset -euo pipefail\n'
        printf 'source %q\n' "${timing_sh}"
        printf 'timing_init "provision-toolchains"\n'
        printf 'timing_span_begin "run playbook"\n'
        printf 'timing_graft_children_from %q\n' "${out}"
        printf 'timing_span_end\n'
    } >"${driver}"
    TIMING_TREE_OUTPUT_PATH="${tree}" run bash "${driver}"
    [ "${status}" -eq 0 ]
    [ -f "${tree}" ]
    if command -v jq >/dev/null 2>&1; then
        # run playbook's children: the Gathering Facts leaf then the role node.
        run bash -c "jq -r '[.. | objects | select(.name==\"run playbook\") | .children[].name]' '${tree}'"
        [[ "${output}" == *'Gathering Facts'* ]]
        [[ "${output}" == *'toolchain_demo'* ]]
        # The role node carries the two tasks as children.
        run bash -c "jq -r '[.. | objects | select(.name==\"toolchain_demo\") | .children[].name] | sort | join(\",\")' '${tree}'"
        [ "${output}" = "demo first task,demo second task" ]
    fi
}
