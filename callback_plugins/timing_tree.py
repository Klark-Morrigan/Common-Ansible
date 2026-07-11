# Aggregate callback that records each task's wall-clock duration and writes the
# per-task rows the shared bash emitter (Common-Automation scripts/timing.sh,
# via its timing_graft_children_from verb) folds into the currently-open timing
# span. It is the missing "inner" emitter for an ansible-playbook child: the bash
# wrapper times the run as one `run playbook` span, and these rows deepen that
# span into `Gathering Facts / <role> -> <task>` in the SAME e2e-timing tree the
# rest of the flow reports on - no sidecar artifact.
#
# Neutral, opt-in, substrate-safe:
#   - Writes ONLY when TIMING_TASKS_OUTPUT_PATH is set (the wrapper points it at
#     a temp file for a timed run and leaves it unset otherwise), so an
#     uninstrumented run pays nothing and the substrate never learns which
#     consumer collects the rows.
#   - Row format matches the bash verb's contract exactly:
#         <role><TAB><task-name><TAB><elapsed_ms><TAB><status>
#     with a blank <role> for roleless tasks (Gathering Facts, play-level tasks).
#
# Timing model mirrors ansible.posix.profile_tasks: a task's duration is the
# wall clock from its start to the next task's start (or to playbook end for the
# last), so the numbers line up with that familiar callback.

from __future__ import annotations

import os
import time

from ansible.plugins.callback import CallbackBase


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "aggregate"
    CALLBACK_NAME = "timing_tree"
    # Aggregate callbacks must be explicitly enabled (ANSIBLE_CALLBACKS_ENABLED);
    # this runs alongside the stdout callback rather than replacing it.
    CALLBACK_NEEDS_ENABLED = True

    def __init__(self):
        super().__init__()
        # Resolve the opt-in target once. Unset -> the callback loads but emits
        # nothing, so enabling it on an untimed run is harmless.
        self._output_path = os.environ.get("TIMING_TASKS_OUTPUT_PATH") or None
        # Finished rows: list of (role, name, elapsed_ms, status).
        self._rows = []
        # The currently-open task, closed when the next one starts.
        self._cur_start = None
        self._cur_role = ""
        self._cur_name = ""
        self._cur_status = "OK"

    def _close_current(self):
        # Fold the in-flight task into a row. Duration is start-to-next-start, so
        # this fires on each new task start and once at playbook end.
        if self._cur_start is None:
            return
        elapsed_ms = int((time.time() - self._cur_start) * 1000)
        self._rows.append(
            (self._cur_role, self._cur_name, elapsed_ms, self._cur_status)
        )
        self._cur_start = None

    def _open_task(self, task):
        self._close_current()
        self._cur_start = time.time()
        name = task.get_name() or ""
        # Role attribution: task._role is the Role object for a role's tasks
        # (set by import_role / include_role) and None for play-level tasks and
        # the implicit Gathering Facts, which then bucket as roleless.
        role = getattr(task, "_role", None)
        role_name = role.get_name() if role else ""
        # For a role task, get_name() returns the display form "<role> : <task>";
        # the role is already the grouping node, so strip that prefix to leave
        # the bare task name (avoids "jdk -> jdk : install tarball").
        prefix = f"{role_name} : "
        if role_name and name.startswith(prefix):
            name = name[len(prefix):]
        self._cur_role = role_name
        self._cur_name = name
        self._cur_status = "OK"

    def v2_playbook_on_task_start(self, task, is_conditional):
        self._open_task(task)

    def v2_playbook_on_handler_task_start(self, task):
        self._open_task(task)

    def v2_runner_on_failed(self, result, ignore_errors=False):
        # A failed host result marks the open task Failed; ignore_errors runs
        # still record Failed because the task itself did fail - the report
        # should show where time went AND that it errored.
        self._cur_status = "Failed"

    def v2_runner_on_unreachable(self, result):
        self._cur_status = "Failed"

    def v2_playbook_on_stats(self, stats):
        # Playbook end: close the last task, then write the rows the bash verb
        # grafts. Defensive on the write - a diagnostics failure must never break
        # the run - and tab/newline-stripped so a task name never corrupts a row.
        self._close_current()
        if not self._output_path:
            return
        try:
            with open(self._output_path, "w", encoding="ascii", errors="replace") as handle:
                for role, name, elapsed_ms, status in self._rows:
                    safe_role = role.replace("\t", " ").replace("\n", " ")
                    safe_name = name.replace("\t", " ").replace("\n", " ")
                    handle.write(f"{safe_role}\t{safe_name}\t{elapsed_ms}\t{status}\n")
        except OSError:
            pass
