# Role: env_vars_report

Renders one plain-text block per host describing which operator-declared
environment variables this VM carries: the managed block each was declared
in, its value as declared, the file it landed in, and whether this run
wrote it.

It writes nothing. It is the terminal consumer of the
`env_vars_report_entries` accumulator
[`vm_env_vars`](../vm_env_vars/README.md) appends to as it reconciles, so
a play gets the report by including this role last.

## Index

- [Why it exists](#why-it-exists)
- [Relationship to the other reports](#relationship-to-the-other-reports)
- [Var contract](#var-contract)
- [Sample output](#sample-output)
- [Reading it](#reading-it)
- [What it does not cover](#what-it-does-not-cover)
- [Consuming this role](#consuming-this-role)
- [Tests](#tests)

## Why it exists

A variable is invisible in a way a transported file is not. A file can be
confirmed with `ls`; a variable is observable only from inside a process
that inherited it, and what an operator wants to confirm is the value such
a process reads back - not the escaped `NAME="value"` line the file
happens to hold. This report is where a declared variable becomes
checkable without opening a session on the VM and echoing it.

Its second answer is what a re-run did. `written` says this run put the
block in place; `unchanged` says the host was already carrying it. That is
the answer to "did my edit actually reach this host", and it exists only
at the moment of the write - a later read of the file sees the same lines
either way.

Its third answer is provenance. `/etc/environment` holds the
distribution's own `PATH`, whatever an operator added by hand, and any
other consumer's managed block. The report lists only what config
declared, grouped by the block it was declared in, so a wrong value leads
straight back to the declaration that produced it.

## Relationship to the other reports

Same shape, same shared tail
([`report_render`](../report_render/README.md)), different subject:

| | [`files_report`](../files_report/README.md) | [`artifact_report`](../artifact_report/README.md) | `env_vars_report` |
| --- | --- | --- | --- |
| Answers | which declared files are on the VM, and where | what a toolchain was installed **from**, and is that still here | which declared variables this VM carries, and from which block |
| Entry granularity | one per file that **landed** - a glob's expansion is knowable only from the run | one per artifact | one per **declared** variable - the schema is flat, so config and report line up one to one |
| Method | reads what `copy` reported | **probes**, because a converged run infers nothing | reads what `blockinfile` reported |

It is the closest peer of `files_report`, because their producers are the
two halves of "what an operator declared for this VM". The one structural
difference is granularity, and it follows from the schemas: a `files`
entry can be a glob that becomes any number of files, so its report has to
be accumulated per file; an `envVars` entry is always exactly one
variable.

The `artifact_report` column is the useful contrast for method.  That role
probes because a converged toolchain run short-circuits on a manifest and
never touches the artifact, so an inferred report would describe a cache
from months ago. Nothing here short-circuits - the block is reconciled on
every run - so `blockinfile` is authoritative about what it just wrote.

## Var contract

Full field documentation lives in
[`defaults/main.yml`](defaults/main.yml). In brief:

- `env_vars_report_entries` (default `[]`) - appended by `vm_env_vars`,
  never set by an operator. **One entry per declared variable.** Each
  carries `block`, `name`, `value`, `target` and `status`
  (`written` | `unchanged`).

Two fields need their meaning stated rather than assumed:

- **`value` is the declared value, not the escaped one.** The backslash
  and quote escaping the file's lines carry is an artefact of the file
  format. What an operator confirms off a report is the value a process
  reads back.
- **`status` is a property of the block, not of the variable.** The block
  is written or left alone as a unit, in one atomic move, so every entry
  from one run shares its value. There is no per-variable change detection
  to be had here, and inventing one would claim precision the mechanism
  does not have.

`target` is quoted from the producing role's own target constant, so the
report cannot name a file the role does not write.

The role also sets `env_vars_report_lines` - the rendered report as a list
of lines - before printing it, so a test or a downstream consumer can
assert on exactly what the operator saw instead of scraping stdout.

This role owns the entry contract and the layout
([`templates/env-vars-report.j2`](templates/env-vars-report.j2)); the
shared mechanics belong to
[`report_render`](../report_render/README.md), which the three sibling
reports also delegate to. See that role's README for why the template
lookup stays in the calling role's var scope.

## Sample output

```text
Environment variables report for ubuntu-02-ci -- 2 written, 1 unchanged
  block app-runtime -- 1 declared in /etc/environment
    unchanged APP_HOME='/opt/app'
  block ci-jars -- 2 declared in /etc/environment
    written   STARSECTOR_HOME='/opt/ci-jars/starsector'
    written   CI_JARS_OPTS='a "quoted" \ backslash'
```

Grouping is by managed block because that is the unit an operator acts on.
A host can carry several consumers' blocks in one file, and the block name
is what says which declaration produced a line - and therefore which one
to go and edit.

The file is on the group heading rather than on every row: it is one fact
per block, and repeating it per variable would push the value, the thing
an operator came to read, off to the right.

Values are printed in **single** quotes, which the file's own
`NAME="value"` lines never use. Both reasons are about not misleading: the
value shown is the declared one, so a double-quoted rendering would invite
reading escaping off a line that carries none, and the quotes are what
make surrounding whitespace visible - otherwise the one kind of wrong
value a report prints indistinguishably from the right one.

Plain ASCII, no colour, for the same reason as the other reports: the text
is emitted through `debug`, and the default callback JSON-encodes the
result - an ANSI escape survives that as its literal backslash form
instead of colouring anything.

## Reading it

| Symptom | What the report shows | Diagnosis |
| --- | --- | --- |
| A service cannot see a variable the report lists | the row is there, `written`, with the right value | The declaration reached the file. `/etc/environment` is parsed by `pam_env` for **login sessions only** - a systemd unit needs an `EnvironmentFile=-/etc/environment` drop-in, which belongs to the repo that owns the unit. |
| A variable config declares is absent | no row, or no group for its block | The flow did not run for this host, or the declaration sits under a `vmName` that does not match it. An entirely empty report says nothing was declared at all. |
| A value carries stray spaces | `NAME='  value  '` | Declared that way. The quotes exist to make exactly this visible; strip it in the config, not on the VM. |
| A run nobody expected to write says `written` | one group flips to `written` | Something diverged from the declaration - typically a hand edit inside the markers, which the reconcile replaces. Change the declaration, not the VM. |
| Everything `unchanged` | no group was rewritten | Fully converged. A run that writes nothing is the steady state, not a failure. |
| A block appears that this operator did not declare | a second group with an unfamiliar name | Another consumer declares variables on this host too. Only the block naming your declaration is yours to edit; the role preserves the rest. |

An empty report - `0 written, 0 unchanged` and a line saying no variables
were declared - means config asked for no environment variables on this
host. That reads deliberately differently from an empty group heading,
which would look like a lost declaration.

## What it does not cover

- **Delivery.** The report describes what reached the file, not what a
  given process inherited. Which units read the file is a question only
  the repo owning those units can answer - see the symptom table above.
- **Retracted blocks.** An empty entry list means "remove this block", and
  the removal contributes no entries: after it the host carries no
  variable from that block, so there is nothing to list. The PLAY output
  still shows the write as `changed`.
- **The file's other lines.** The distribution's `PATH`, operator
  additions and any block no role in this play reconciled are outside the
  accumulator by construction. The report is what config declared, not an
  inventory of the file.
- **The rendered form.** No escaped `NAME="value"` line is shown. The
  escaping is the file format's business, and printing it would give an
  operator two spellings of one value to reconcile.
- **Residency.** The report describes what the reconcile wrote, not the
  file at some later moment. (Contrast `artifact_report`, which probes
  precisely because a converged run touches nothing.)

## Consuming this role

Include it **last**, after every role that reconciles a managed block, so
the accumulator is complete:

```yaml
- name: Report the environment variables declared for each host
  ansible.builtin.import_role:
    name: env_vars_report
  tags:
    - env_vars_report
    - always
```

The `always` tag is deliberate: a targeted run still gets a report, scoped
to whatever actually ran.

With no entries the role renders the empty-run block described above, so a
play can include it unconditionally.

## Tests

`Tests/molecule/env_vars_report/default` seeds a representative entry set
through molecule inventory vars and asserts the rendered
`env_vars_report_lines`:

| Case | What it pins down |
| --- | --- |
| Two blocks | The grouping is grouping, not one block with a heading - and each group carries its own count and file |
| Both statuses, one per block | The header counts them, and each row carries its own - varying **across** blocks and uniform **within** one, which is the only shape the producer can emit |
| A value carrying a quote and a backslash | The report prints the value as declared; the `\"` and `\\` the file's own line carries appear nowhere |
| A value with surrounding whitespace | The quotes make it visible, which is what stops the one wrong value that would otherwise render identically to the right one |
| Declaration order within a group | Rows keep accumulator order, so a group reads against the config it came from line by line |
| A block spanning two files | The heading names both rather than reporting one of them - legal under the contract, since `target` is per entry, though today's only producer fixes it to a constant |
| One block only | The other group is **absent**, not an empty heading - which would read as a declaration that lost its variables |
| No entries at all | Reads as "nothing was declared" rather than as an empty heading |

Every case after the first renders a subset or a minimal mutation of the
same seeded set rather than a second fixture, so a case cannot drift away
from the mixed one it is cut from.

One shape is deliberately **not** seeded: a mixed status inside one group.
The mechanism cannot produce it - the block is written or left alone as a
unit - so a fixture carrying one would be testing a report of something
that cannot happen. That is what separates it from the two-file case
above, which the contract permits and only today's producer declines to
emit.

Seeding through inventory (rather than in `converge.yml`) is what lets
`verify.yml` re-render from the same source: facts set during converge do
not survive into the verifier's separate `ansible-playbook` run.

Rows are asserted as whole exact lines. Values here carry regex
metacharacters (a backslash, a quote), and an exact line also pins the
columns - a row that lost its quoting, or a status that stopped being
padded into a column, is a report an operator can no longer scan.

Seeded entries cannot prove the producer still emits the shape this
template reads, so
[`Tests/molecule/vm_env_vars/default`](../vm_env_vars/README.md#tests)
renders the report from the accumulator a real reconcile produced. That is
where the two halves of the contract meet; a field `vm_env_vars` stopped
emitting fails there rather than in front of an operator.
