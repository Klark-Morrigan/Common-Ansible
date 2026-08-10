# Role: artifact_report

Renders one plain-text block per host describing where each toolchain's
**artifact** came from and where it sits on the VM right now: the source
URL, the cache path, the probed size and mtime of that file, and the
directory it was unpacked into.

It installs nothing. It is the terminal consumer of the
`artifact_report_entries` accumulator the acquiring roles append to, so a
play gets the report by including this role last.

## Index

- [Why it exists](#why-it-exists)
- [Relationship to toolchain_report](#relationship-to-toolchain_report)
- [Var contract](#var-contract)
- [Sample output](#sample-output)
- [Reading it during a build failure](#reading-it-during-a-build-failure)
- [Producing roles](#producing-roles)
- [What it does not cover](#what-it-does-not-cover)
- [Consuming this role](#consuming-this-role)
- [Tests](#tests)

## Why it exists

A broken build on a provisioned VM is usually diagnosed by walking
backwards from the failing binary to the artifact it came out of: is the
tarball still in the cache, is it the size it should be, when did it land,
and did the extract actually produce the directory the manifest claims.

None of that chain is visible in a normal run. The download is skipped on
a cache hit, and on a fully converged run the acquisition code never
executes at all - so the run that most needs the answer is the run that
prints the least.

## Relationship to toolchain_report

Two reports, two questions:

| | [`toolchain_report`](../toolchain_report/README.md) | `artifact_report` |
| --- | --- | --- |
| Answers | what is installed and what does it own | what was it installed **from**, and is that still here |
| Source | the on-disk manifests + the reconcile's diff sets | a live `stat` of each artifact and its unpacked directory |
| Method | infers status from the diff | **probes**, because a converged run infers nothing |
| Scope | installed, present and removed versions | the desired set only |

The pair is deliberate: `toolchain_report` saying `present` while
`artifact_report` says the install directory is `MISSING` is a complete
diagnosis on its own - the manifest claims paths that are gone, so every
symlink into them dangles.

## Var contract

Full field documentation lives in
[`defaults/main.yml`](defaults/main.yml). In brief:

- `artifact_report_entries` (default `[]`) - appended by the producing
  roles, never set by an operator. Each entry carries `tool`, `version`,
  `section`, `source`, `transfer`, and two nested probe results:
  `artifact` (`path`, `present`, `size`, `mtime`, `note`) and `unpacked`
  (`dir`, `present`). The probe fields are nested rather than flattened
  because each group is a set of facets of a single `stat`, and a producer
  should not have to restate four key names to record one file.

`transfer` records what **this run** did: `downloaded` (bytes moved),
`reused-cache` (needed it, found it already on the VM), or `none` (nothing
to install, so nothing was fetched). Residency is separate and always
probed, so `transfer: none` alongside a present artifact is the normal
steady state, not a contradiction.

The role also sets `artifact_report_lines` - the rendered report as a list
of lines - before printing it, so a test or a downstream consumer can
assert on exactly what the operator saw instead of scraping stdout.

This role owns the entry contract and the layout
([`templates/artifact-report.j2`](templates/artifact-report.j2)); the
shared mechanics belong to [`report_render`](../report_render/README.md),
which [`toolchain_report`](../toolchain_report/README.md) also delegates
to. See that role's README for why the template lookup stays in the
calling role's var scope.

## Sample output

```text
Artifact report for ubuntu-02-ci -- 1 downloaded, 0 reused from cache, 3 not needed; 1 MISSING
section 1 - host-pushed (fetched from the controller file server)
  jdk 17.0.20+8  [transfer: none]
      source    http://192.168.137.1:8080/OpenJDK17U-jdk_x64_linux_hotspot_17.0.20_8.tar.gz
      artifact  /var/cache/common-ansible/toolchains/OpenJDK17U-jdk_x64_linux_hotspot_17.0.20_8.tar.gz
                present, 195.3 MB, modified 2026-06-09 17:13
      unpacked  /opt/jdk-17.0.20+8  present
  dotnet 10.0.100  [transfer: downloaded]
      source    http://192.168.137.1:8080/dotnet-sdk-10.0.100-linux-x64.tar.gz
      artifact  /var/cache/common-ansible/toolchains/dotnet-sdk-10.0.100-linux-x64.tar.gz
                present, 229.0 MB
      unpacked  /opt/dotnet-10.0.100  present
  powershell 7.6.4  [transfer: none]
      source    http://192.168.137.1:8080/powershell-7.6.4-linux-x64.tar.gz
      artifact  /var/cache/common-ansible/toolchains/powershell-7.6.4-linux-x64.tar.gz
                MISSING
      unpacked  /opt/powershell-7.6.4  present
  dotnet-reportgenerator-globaltool 5.4.5  [transfer: none]
      source    http://192.168.137.1:8080/dotnet-tool-dotnet-reportgenerator-globaltool-5.4.5.nupkg
      artifact  not retained - the .nupkg is staged under /var/lib/common-ansible/toolchains/dotnet-tool-staging/<key> and wiped once the driver has installed from it
      unpacked  /usr/local/share/dotnet/tools/.store/dotnet-reportgenerator-globaltool/5.4.5  present
section 2 - vm-downloaded (the VM fetches these itself)
  bats-support 0.3.0  [transfer: none]
      source    https://github.com/bats-core/bats-support/archive/refs/tags/v0.3.0.tar.gz
      artifact  not retained - the tag tarball is streamed into the library directory by remote_src unarchive, so it never lands as a file; presence below is probed via that directory's load.bash
      unpacked  /usr/lib/bats-support  present
```

`MISSING` is uppercase because it is the one word an operator scans a wall
of paths for. The header repeats the count so a clean run is one glance.

## Reading it during a build failure

| Symptom | What the report shows | Diagnosis |
| --- | --- | --- |
| `java: command not found` while `toolchain_report` says `present` | `unpacked` MISSING | The install directory was deleted out from under the manifest. Symlinks in `/usr/local/bin` dangle. Remove the manifest to force a reinstall. |
| A tool starts but misbehaves | `artifact` present at an unexpected size | Truncated or partial download in the cache. Delete the cached file and the manifest, then re-run. |
| A version you did not expect is running | two entries for one tool | Two versions are desired at once, or a stale install dir survived a swap. |
| Everything `present`, build still broken | nothing anomalous | The toolchain landed correctly; look past provisioning. |

`artifact` present alongside `unpacked` MISSING is the recoverable case -
the bytes are already on the VM, so a reinstall needs no network.

## Producing roles

| Role | Section | Artifact | Retained on the VM |
| --- | --- | --- | --- |
| [`toolchain_host_push`](../toolchain_host_push/README.md) (via `jdk`, `dotnet_sdk`, `powershell`) | `host-push` | the tarball, from the controller's file server | yes - `/var/cache/common-ansible/toolchains/<archive>` |
| [`dotnet_tools`](../dotnet_tools/README.md) | `host-push` | the `.nupkg`, from the controller's file server | no - staged, then wiped after the driver installs from it |
| [`toolchain_bats_libs`](../toolchain_bats_libs/README.md) | `vm-download` | the GitHub tag tarball | no - streamed straight into the library directory |

`transfer` for the host-push tarballs is logged inside the install loop
(`_install-version.yml`), because that is the only place the
downloaded-vs-cache-hit distinction survives: afterwards the cache file
looks identical whether it landed now or months ago. The other two need no
log - neither has a cache short-circuit, so being in the `missing` set is
itself the record that bytes moved.

## What it does not cover

- **apt packages and the Docker engine.** dpkg owns its own download cache
  and its own file record; this stack transfers nothing for them. They
  appear in `toolchain_report` as dpkg-managed and are absent here.
- **Versions this run removed.** Uninstall deliberately leaves the cached
  tarball behind, but a manifest does not record an archive name, so an
  orphaned tarball cannot be attributed back to the tool that fetched it.
  Closing that gap needs a manifest schema change. `toolchain_report` still
  shows the removal and every path it tore down.
- **Checksums.** `get_checksum` is off. Hashing a 200 MB tarball per run
  would dominate the report's cost; size and mtime are the cheap proxy, and
  integrity is verified controller-side before staging anyway.

## Consuming this role

Include it **last**, after every toolchain role in the play, so the
accumulator is complete:

```yaml
- name: Report the toolchain artifacts resident on each host
  ansible.builtin.import_role:
    name: artifact_report
  tags:
    - artifact_report
    - always
```

The `always` tag is deliberate: a targeted run (`--tags jdk`) still gets a
report, scoped to whatever actually ran.

## Tests

`Tests/molecule/artifact_report/default` seeds a representative entry set
through molecule inventory vars - covering both sections, all three
transfer states, a retained artifact with size and mtime, a missing
artifact, a missing unpacked directory, and two not-retained mechanisms -
and asserts the rendered `artifact_report_lines`.

Seeding through inventory (rather than in `converge.yml`) is what lets
`verify.yml` re-render from the same source: facts set during converge do
not survive into the verifier's separate `ansible-playbook` run.
