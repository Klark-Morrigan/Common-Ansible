# Role: toolchain_report

Renders one plain-text block per host summarising what the toolchain roles
just did: which tool versions this run **installed**, which were already
**present**, which it **removed**, and the exact paths each one owns on the
VM.

It installs nothing. It is the terminal consumer of the
`toolchain_report_entries` accumulator that every toolchain role appends to
while it reconciles, so a play gets the report by including this role last.

## Index

- [Why it exists](#why-it-exists)
- [Var contract](#var-contract)
- [Sample output](#sample-output)
- [Why an accumulator, not a terminal scan](#why-an-accumulator-not-a-terminal-scan)
- [Producing roles](#producing-roles)
- [Consuming this role](#consuming-this-role)
- [Tests](#tests)

## Why it exists

Ansible's per-task output answers "did this task change something"; it does
not answer the operator's actual question after a provisioning run - *what
is on this VM now, where does it live, and did this run put it there*. On a
converged run the answer is invisible: every reconcile short-circuits on
its manifest, the install tasks report `skipping`, and the paths never get
printed at all even though they are recorded on the VM.

This role turns that recorded state into a readable block, once per host.

## Var contract

Full field documentation lives in
[`defaults/main.yml`](defaults/main.yml). In brief:

- `toolchain_report_entries` (default `[]`) - appended by the producing
  roles, never set by an operator. Each entry carries `tool`, `version`,
  `section`, `status`, and optionally `install_dir`, `symlinks`
  (`{path, target}` pairs) and `files` (any other owned absolute path).

The role also sets `toolchain_report_lines` - the rendered report as a list
of lines - before printing it, so a test or a downstream consumer can
assert on exactly what the operator saw instead of scraping stdout.

This role owns the entry contract and the layout
([`templates/toolchain-report.j2`](templates/toolchain-report.j2)); the
shared mechanics of turning rendered text into readable operator output
and an assertable fact belong to
[`report_render`](../report_render/README.md), which
[`artifact_report`](../artifact_report/README.md) also delegates to. The
template lookup happens in *this* role's var scope, so it resolves against
this role's `templates/` with no search-path ambiguity - `report_render`
never needs to know a template name.

## Sample output

```text
Toolchain report for ubuntu-02-ci -- 1 installed, 5 present, 0 removed
section 1 - host-pushed (staged on the controller, pulled from the file server)
  present   jdk 17.0.20+8
      dir   /opt/jdk-17.0.20+8
      link  /usr/local/bin/java -> /opt/jdk-17.0.20+8/bin/java
      link  /usr/local/bin/javac -> /opt/jdk-17.0.20+8/bin/javac
      file  /etc/profile.d/jdk.sh
  installed dotnet 10.0.100
      dir   /opt/dotnet-10.0.100
      link  /usr/local/bin/dotnet -> /opt/dotnet-10.0.100/dotnet
      file  /etc/dotnet/install_location
section 2 - vm-downloaded (the VM fetches these itself)
  present   shellcheck 0.9.0-1
      (dpkg-managed - the package manager owns these paths)
  present   bats-support 0.3.0
      dir   /usr/lib/bats/bats-support
      file  /usr/lib/bats/bats-support/load.bash
      file  /usr/lib/bats/bats-support/.installed-v0.3.0
section 3 - base-image (daemon installed from a vendor repo)
  present   docker 5:27.3.1-1~ubuntu.24.04~noble
      (dpkg-managed - the package manager owns these paths)
```

Symlinks are listed in full rather than counted: an operator debugging
"which `java` am I actually running" needs the exact link, not a total.

## Why an accumulator, not a terminal scan

Status is only knowable at the moment each role diffs desired against
installed. A scan of the finished filesystem sees the end state but cannot
tell a version this run installed from one that was already there, and
cannot see a removed version at all - its manifest is deleted by then.

Paths come from the manifests rather than from the caller's desired-state
entry for the same reason of accuracy: a host-push tool using
`symlink_bin_dir` (the JDK's ~50 launchers) only learns its full symlink
set at install time, and the manifest is where that lands.

## Producing roles

| Role | Section | Status source | Paths reported |
| --- | --- | --- | --- |
| [`toolchain_host_push`](../toolchain_host_push/README.md) (via `jdk`, `dotnet_sdk`, `powershell`) | `host-push` | the `missing` / `stale` diff sets | manifest: install dir, every symlink, the profile.d script, owned files |
| [`dotnet_tools`](../dotnet_tools/README.md) | `host-push` | the `missing` / `stale` diff sets | manifest: store dir and every driver shim |
| [`toolchain_apt`](../toolchain_apt/README.md) | `vm-download` | a `dpkg-query` snapshot taken before the install | none - dpkg owns them |
| [`toolchain_bats_libs`](../toolchain_bats_libs/README.md) | `vm-download` | the installed-version marker probe | library dir, `load.bash`, the marker |
| [`docker`](../docker/README.md) | `base-image` | the engine install task's `changed` flag | none - dpkg owns them |

A role that contributes nothing (empty desired set) appends nothing, and a
play that includes this role alone reports an empty run - which is itself
informative.

## Consuming this role

Include it **last**, after every toolchain role in the play, so the
accumulator is complete:

```yaml
- name: Report the toolchain reconciliation outcome
  ansible.builtin.import_role:
    name: toolchain_report
  tags:
    - toolchain_report
    - always
```

The `always` tag is deliberate: a targeted run (`--tags jdk`) still gets a
report, scoped to whatever actually ran.

## Tests

`Tests/molecule/toolchain_report/default` seeds a representative entry set
through molecule inventory vars - covering all three sections, all three
statuses, an entry with symlinks and files, and a dpkg-managed entry with
neither - and asserts the rendered `toolchain_report_lines`.

Seeding through inventory (rather than in `converge.yml`) is what lets
`verify.yml` re-render from the same source: facts set during converge do
not survive into the verifier's separate `ansible-playbook` run.
