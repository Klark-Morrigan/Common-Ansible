# Role: files_report

Renders one plain-text block per host describing which operator-declared
files reached this VM: where each came from, the path it landed on, what
owns it, and whether this run wrote it.

It copies nothing. It is the terminal consumer of the
`files_report_entries` accumulator [`vm_files`](../vm_files/README.md)
appends to as it transports, so a play gets the report by including this
role last.

## Index

- [Why it exists](#why-it-exists)
- [Relationship to the toolchain reports](#relationship-to-the-toolchain-reports)
- [Var contract](#var-contract)
- [Sample output](#sample-output)
- [Reading it](#reading-it)
- [What it does not cover](#what-it-does-not-cover)
- [Consuming this role](#consuming-this-role)
- [Tests](#tests)

## Why it exists

A bulk entry is one line of config that becomes an unknown number of
files. An operator reading the config knows a glob was declared; only the
run knows what it matched, and only the run knows what each match was
named once `preserveRelativePath` had its say - a target carrying `v1/`
where the pattern carried `v*` appears nowhere in the config.

The PowerShell engine that has owned this schema never printed that
expansion. "Which JARs actually reached the VM, and under what names" was
answerable only by going and looking, which is the gap this closes.

The second question it answers is what a re-run did. `copied` names
exactly the files this run wrote; `unchanged` names the ones that were
already correct. That distinction exists only at the moment of the copy -
a scan of the finished VM sees the file either way - which is why the
report is accumulated as the transport happens rather than derived
afterwards.

## Relationship to the toolchain reports

Same shape, same shared tail
([`report_render`](../report_render/README.md)), different subject:

| | [`toolchain_report`](../toolchain_report/README.md) | [`artifact_report`](../artifact_report/README.md) | `files_report` |
| --- | --- | --- | --- |
| Answers | what is installed and what does it own | what was it installed **from**, and is that still here | which declared files are on the VM, and where |
| Source | on-disk manifests + the reconcile's diff sets | a live `stat` of each artifact | the transport's own results |
| Method | infers status from the diff | **probes**, because a converged run infers nothing | reads what `copy` reported |

The middle column is the one to contrast. `artifact_report` probes because
a converged toolchain run short-circuits on a manifest and never touches
the artifact, so an inferred report would describe a cache from months
ago. Nothing here short-circuits - every declared file is reconciled on
every run - so `copy` is authoritative about the file it just wrote, and a
`stat` per file would spend a round trip per JAR to restate it.

## Var contract

Full field documentation lives in
[`defaults/main.yml`](defaults/main.yml). In brief:

- `files_report_entries` (default `[]`) - appended by `vm_files`, never set
  by an operator. **One entry per file that landed, not per declared
  entry**: a bulk entry contributes as many as its glob matched. Each
  carries `source`, `target`, `owner`, `group`, `mode`, `status`
  (`copied` | `unchanged`), `origin` (`single` | `bulk`) and `pattern`
  (`""` for a named file).

`owner`, `group` and `mode` are quoted from the transport's own policy
constants rather than re-stated here, so the report cannot describe
ownership the role does not enforce.

The role also sets `files_report_lines` - the rendered report as a list of
lines - before printing it, so a test or a downstream consumer can assert
on exactly what the operator saw instead of scraping stdout.

This role owns the entry contract and the layout
([`templates/files-report.j2`](templates/files-report.j2)); the shared
mechanics belong to [`report_render`](../report_render/README.md), which
both toolchain reports also delegate to. See that role's README for why the
template lookup stays in the calling role's var scope.

## Sample output

```text
Files report for ubuntu-02-ci -- 2 copied, 4 unchanged
section 1 - named files (one declared entry, one file)
  copied    /etc/app/app.conf  root:root 0644
      source  /mnt/c/estate/config/app.conf
  unchanged /etc/app/logging.json  root:root 0644
      source  /mnt/c/estate/config/logging.json
section 2 - glob matched files (one declared entry, every file it named)
  pattern /mnt/c/estate/jars/*.jar -- 3 landed
    unchanged /opt/app/lib/engine-4.2.1.jar  root:root 0644
        source  /mnt/c/estate/jars/engine-4.2.1.jar
    unchanged /opt/app/lib/plugins-4.2.1.jar  root:root 0644
        source  /mnt/c/estate/jars/plugins-4.2.1.jar
    copied    /opt/app/lib/telemetry-1.0.0.jar  root:root 0644
        source  /mnt/c/estate/jars/telemetry-1.0.0.jar
  pattern /mnt/c/estate/sites/v*/site.ini -- 1 landed
    unchanged /etc/app/sites/v1/site.ini  root:root 0644
        source  /mnt/c/estate/sites/v1/site.ini
```

The two sections read differently, which is why they are sections. A named
file is one line of config and one file, so it can be checked against the
config by eye. A matched file cannot: the pattern above it is the only
thing that says which line of config put it there, and the count beside it
is what makes an expansion checkable at a glance - an operator who
expected four JARs and reads `3 landed` has their answer without reading
the rows.

A group is per **pattern**, not per declared entry, so one glob declared
twice with two `targetDir`s renders as a single group listing both
landings. Its count therefore reads `landed`, not `matched`: the question
the report answers is which files reached the VM and where, not how many
lines of config asked for them.

Plain ASCII, no colour, for the same reason as the other reports: the text
is emitted through `debug`, and the default callback JSON-encodes the
result - an ANSI escape survives that as its literal backslash form
instead of colouring anything.

## Reading it

| Symptom | What the report shows | Diagnosis |
| --- | --- | --- |
| An expected file is not on the VM | its pattern's group has a lower count than expected | The glob matched less than the operator thought. Compare a listed source path against what is actually on the controller volume. |
| A file is on the VM but the app cannot read it | `root:root 0644` | Working as specified. User-owned content is out of scope here - it belongs to the users layer, which runs once the users exist. |
| Two config lines, one group | one `pattern` heading, targets under two directories | The same glob is declared twice with different `targetDir`s. Both landings happened; the report merges the heading. |
| A hand-edit was overwritten | that file reads `copied` on a run nobody expected to write | The transport reconciles, so a hand-edited target is replaced on the next run. Change the source, not the VM. |
| Every file `unchanged` | nothing was written | Fully converged. A run that copies nothing is the steady state, not a failure. |

An empty report - `0 copied, 0 unchanged` and a line saying no entries were
declared - means config asked for no files on this host. That reads
deliberately differently from an empty section heading, which would look
like a lost entry.

## What it does not cover

- **Residency.** The report describes what the transport reconciled, not
  what is on the VM at some later moment. `copy` is authoritative about the
  file it just wrote; a file deleted after the run is not this report's
  subject. (Contrast `artifact_report`, which probes precisely because a
  converged run touches nothing.)
- **Content.** No checksum is rendered. `copy` compares checksums to decide
  whether to write at all, so `unchanged` already means "the bytes match";
  printing the hash would cost a column per file to restate that.
- **Files this run removed.** The schema declares files that should be
  present and has no removal form, so there is nothing to report.
- **Directories the transport created.** They are a means to an end - the
  parent of a target - and an operator debugging a missing file needs the
  file's path, which is on the row above.

## Consuming this role

Include it **last**, after every role that transports files, so the
accumulator is complete:

```yaml
- name: Report the files transported to each host
  ansible.builtin.import_role:
    name: files_report
  tags:
    - files_report
    - always
```

The `always` tag is deliberate: a targeted run still gets a report, scoped
to whatever actually ran.

With no entries the role renders the empty-run block described above, so a
play can include it unconditionally.

## Tests

`Tests/molecule/files_report/default` seeds a representative entry set
through molecule inventory vars and asserts the rendered
`files_report_lines`:

| Case | What it pins down |
| --- | --- |
| Both origins | Named files and matched files render in their own sections |
| Both statuses | The header counts them, and each row carries its own |
| Two statuses under one pattern | Status is per file, not per declared entry - which is why the accumulator holds one entry per file |
| Two patterns | The grouping is grouping, not one block with a heading |
| A preserved sub-tree target | The report prints `v1/` where the pattern says `v*` - a path obtainable only from the run |
| No entries at all | Reads as "nothing was declared" rather than as an empty heading |

Seeding through inventory (rather than in `converge.yml`) is what lets
`verify.yml` re-render from the same source: facts set during converge do
not survive into the verifier's separate `ansible-playbook` run.

Rows are asserted as whole exact lines. Every path involved carries regex
metacharacters, and an exact line also pins the columns - a target that
lost its ownership suffix, or a status that stopped being padded into a
column, is a report an operator can no longer scan.

Seeded entries cannot prove the producer still emits the shape this
template reads, so
[`Tests/molecule/vm_files/bulk`](../vm_files/README.md#tests) renders the
report from the accumulator a real transport produced. That is where the
two halves of the contract meet; a field `vm_files` stopped emitting fails
there rather than in front of an operator.
