# Role: vm_env_vars

Reconciles a sentinel-delimited managed block of system-wide environment
variables inside `/etc/environment` on a provisioned VM.

Its input is the `envVars` object of a VM definition, reproduced field for
field. The estate already speaks that schema - a PowerShell engine has
owned it since before this role existed - so the sub-field names and their
validation rules are ported rather than redesigned: a definition a
consumer's config already carries is valid here unchanged, and is accepted
or rejected identically whichever engine runs it.

Peer of [`vm_files`](../vm_files/README.md), and deliberately shaped like
it. The two are the halves of "what an operator declared for this VM": one
moves the payload, this one moves the variables that let the VM find it.

## Index

- [Declaration contract](#declaration-contract)
- [Why the role validates its own input](#why-the-role-validates-its-own-input)
- [The managed block](#the-managed-block)
- [Compatibility with the PowerShell engine](#compatibility-with-the-powershell-engine)
- [What it reports](#what-it-reports)
- [Security](#security)
- [Consuming this role](#consuming-this-role)
- [Tests](#tests)

## Declaration contract

Full field documentation lives in
[`defaults/main.yml`](defaults/main.yml). In brief:

| Var | Meaning |
| --- | --- |
| `vm_env_vars_block_name` | The name embedded in the `BEGIN` / `END` sentinel markers delimiting this consumer's block |
| `vm_env_vars_entries` | The desired variables, each a `name` / `value` pair |

The two are supplied together because they mean nothing apart: the entries
are the content, the block name is what says where that content starts and
stops.

| Field | Rule |
| --- | --- |
| `blockName` | 1-128 chars matching `^[A-Za-z0-9._ -]+$`, no leading or trailing whitespace |
| `name` | A POSIX identifier: `^[A-Za-z_][A-Za-z0-9_]*$` |
| `value` | A non-empty string carrying no newline, carriage return or NUL |

Names must be unique across entries. Two entries writing one key is an
operator intent that cannot be honoured, and silently keeping the last
would mask it.

**Three states, not two.** Both fields unset is a no-op, so a play can
always include the role. A block name with an **empty** entry list is not
the same thing - it is the retraction intent, "remove this block", which
is how an operator takes a variable back off a host. Entries without a
block name is an error, not a no-op: there is no defensible default for
the markers, and treating it as one would turn a missing `blockName` into
a run that reported success and wrote nothing.

## Why the role validates its own input

The role is a provisioning vector in its own right, not a downstream stage
of some other engine's pre-pass. It cannot assume any validation has
already run, so it performs its own - and performs it before the write, so
a rejected run leaves the file exactly as it found it.

Unknown sub-fields are rejected. Strictness is deliberate and matches
every other field of the VM schema: an operator who wrote `values:`
instead of `value:` would otherwise get a run that reported success and
left the variable unset, and would then go looking for the fault on the
consuming end.

Every rejection names the offending entry by position and by host, because
"must be a string" on its own does not tell an operator which of a dozen
entries in which VM definition to go and fix.

The work is split across four files, by what each one protects:

| File | Owns |
| --- | --- |
| [`tasks/main.yml`](tasks/main.yml) | The two top-level shapes, the three-state gate, and the write |
| [`tasks/_assert-block-name.yml`](tasks/_assert-block-name.yml) | The marker - length, permitted characters, surrounding whitespace |
| [`tasks/_assert-entries.yml`](tasks/_assert-entries.yml) | The content - one task per rule, looping every entry |
| [`tasks/_record-report.yml`](tasks/_record-report.yml) | Projecting what the reconcile did into the report |

The entry rules are one task per rule rather than one include per entry,
which is where the layout departs from `vm_files`. The schema here is flat
- there is no second entry form to discriminate, which is the only thing
that earned that role its per-entry dispatcher. Ordering carries the
dependencies instead: a task that dereferences a sub-field runs after the
task that proved the sub-field is there.

That ordering matters more than it looks. `fail_msg` is rendered on
**every** run, passing or not, so a message dereferencing a sub-field
whose presence has not yet been asserted would fail the happy path rather
than the failing one.

The allow-list and the regexes live in [`vars/main.yml`](vars/main.yml),
not `defaults/`, precisely so a consumer cannot widen one locally and fork
the schema.

## The managed block

The role owns the lines between its own markers and nothing else:

```ini
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# BEGIN ci-jars
STARSECTOR_HOME="/opt/ci-jars/starsector"
# END ci-jars
```

Everything outside them - the distribution's own `PATH`, operator
additions, **another consumer's block** - is preserved byte for byte. That
is what the per-consumer block name buys: a single shared sentinel would
let the last writer wipe every other consumer's keys.

The write is one `blockinfile` call, which lands via a temp file and a
move, so the file is either the old version or the new version at every
observable moment - never a partial write. That mechanism being already
present is why the module is reused rather than the PowerShell transport's
bash fragment being ported; the marker spelling is the only thing the two
engines have to agree on.

Values are rendered as `NAME="value"`, escaping backslash **first** and
then double-quote. The order is the whole correctness of that line:
escaping backslash second would re-escape the backslashes just emitted for
the quotes. Both parsers that read this file - `pam_env` and systemd's
`EnvironmentFile=` - read `"..."` with exactly those two escapes, which is
why they are the two applied and the only two.

The file is left `root:root 0644`, stated on the write rather than
inherited, and the target is fixed rather than configurable. The target is
the point: `/etc/environment` is the one file that both `pam_env` (login
sessions) and a systemd unit's `EnvironmentFile=` can be pointed at, which
is what lets one declaration serve both.

## Compatibility with the PowerShell engine

The same `envVars` object is also written by `Set-VmEnvironmentVariables`
in `Infrastructure.HyperV`. Both engines are live, so a host may see
either, and the block one writes has to be the block the other recognises
rather than a second block appended beside it.

Three things make that hold, and they are the reason each is spelled the
way it is:

- **The markers.** `# BEGIN <name>` / `# END <name>`, byte for byte. Both
  parsers that read the file skip them as comments.
- **The content lines.** `NAME="value"` with the same two escapes in the
  same order.
- **The schema.** Ported rule for rule, so neither engine accepts a
  definition the other would refuse.

What is **not** identical is where the block ends up. The PowerShell
transport strips the block and re-appends it at end of file; `blockinfile`
replaces it in place. Both leave a well-formed block the other will find
and replace, so the two never fight - a host handed back and forth between
them just sees its block migrate to the end once.

## What it reports

The role appends one entry to the play-wide `env_vars_report_entries`
accumulator per **declared variable**, each carrying its block, its name,
the value as declared, the file it landed in, and whether this run wrote
it (`written`/`unchanged`).

Two properties of that projection are deliberate:

- **The value is the declared one, not the escaped one.** The escaping is
  an artefact of the file format; what an operator wants to confirm is the
  value a process will actually read back.
- **Status is a property of the block, so every entry from one run shares
  it.** The block is written or left alone as a unit, in one move. There
  is no per-variable change detection to be had here, and inventing one
  would be a report claiming precision the mechanism does not have.

The retraction path contributes nothing, which is the honest answer: after
an empty-entries run the host carries no variable from this block, so
there is nothing to list.

Recording is its own task file rather than part of the write because it is
a different concern: what the host carries, and what an operator is told
about it.

> **TODO** - no role renders this accumulator yet. `vm_files` closes its
> flow with [`files_report`](../files_report/README.md); the peer for this
> one is not built, so today the accumulator is readable as a fact but is
> not printed. The renderer belongs with the flow that consumes it.

## Security

`/etc/environment` is world-readable, and that is the file's existing
posture rather than a choice made here - the role writes `0644` because
every reader of the file needs it. Two consequences worth stating:

- **Nothing secret belongs in a VM's `envVars`.** Every user and every
  service on the host can read the file. Secrets belong in a channel that
  masks them.
- **Whatever is declared here reaches everything that reads the file.**
  Scoping a variable to one consumer is not something a block name does -
  it names the block, not its audience. A variable that must reach only
  one service belongs in that service's own environment file.

## Consuming this role

```yaml
- name: Reconcile the declared environment variables on this VM
  ansible.builtin.include_role:
    name: vm_env_vars
  vars:
    vm_env_vars_block_name: ci-jars
    vm_env_vars_entries:
      - name: STARSECTOR_HOME
        value: /opt/ci-jars/starsector
```

With neither var set the role is a no-op, so a play can always include it
and let config decide whether this host declares anything.

A systemd service does **not** read `/etc/environment` on its own -
`pam_env` parses it for login sessions only. A unit that needs these
variables has to be given an `EnvironmentFile=-/etc/environment` drop-in,
which is the consuming repo's job, not this role's: the role writes the
file, and which units are entitled to read it is a question only the repo
that owns those units can answer.

## Tests

`Tests/molecule/vm_env_vars/default` covers the block itself. Its
`prepare.yml` seeds `/etc/environment` with content the role must not own
- the distribution's `PATH`, a hand-added operator line, and **another
consumer's managed block** - and seeds it `nobody:nogroup 0600`, so the
verifier's `root:root 0644` assertion proves the policy is applied rather
than merely inherited.

| Case | What it pins down | Where |
| --- | --- | --- |
| Fresh write | The block lands below the seeded lines, with the expected markers and rendered lines | converge + verify |
| Escaping | A value carrying a quote **and** a backslash renders `\"` and `\\`, which a value with only one of the two would never reveal | converge + verify |
| Value with surrounding whitespace | The block text is trimmed before it reaches `blockinfile`; the closing quote is all that keeps that trim off an operator's own spaces, so the padded value is declared **last** | converge + verify |
| Idempotent re-run | A host whose block is already correct reports `changed=0` rather than rewriting the file every run | `molecule idempotence` |
| Nothing declared | The no-op promise holds, rather than tripping over an empty loop, and contributes nothing to the report | converge |
| Retraction of a block never written | A removal contributes no report entry, since the host then carries no variable from that block | converge |
| Block replacement | A value changes, a variable is **dropped** and one is added - all under one block name, with the surroundings intact | verify |
| Retraction | An empty entry list removes the block, leaving the file byte-identical to its seed | verify |
| No environment file at all | The write creates it `root:root 0644` holding just the block; the retraction leaves it **absent** rather than manufacturing an empty one | verify |

The mutating cases run in `verify.yml` because it runs after
`idempotence`; folding them into the converge would make the converge
non-idempotent by construction, since its second run would put the first
run's entries back.

Each assertion compares the **whole file**, line for line, rather than one
property at a time. The block's content, its markers, its position and the
untouched surroundings are not separable claims - they are the file - and
comparing it whole is the only check that also fails when the role writes
something nobody asked for. The retraction case compares bytes rather than
lines, which is the strongest claim the scenario makes: after a block is
written, replaced and removed, no orphaned marker, no blank line and no
disturbed rival block may remain.

The marker spelling is written out in the test rather than read from the
role's vars. It is the whole compatibility contract with the PowerShell
engine, so a test that derived it would agree with the role however the
role spelled it.

`Tests/molecule/vm_env_vars/schema` covers the contract from both sides.
Its `converge.yml` is the positive control - a block name using every
permitted character class, and entries covering a leading underscore, a
digit-bearing name and a value carrying both escaped characters - and
`verify.yml` runs the rejection matrix, one case per rule, each a minimal
mutation of a shape the converge accepts.

Every rejection case applies the real role and asserts on the message it
produced, so the matrix cannot drift into agreeing with a broken role. The
cases assert the diagnostic too, not merely that something failed: a
rejection that does not name the violated rule and the offending entry's
position fails the test.

The apply-and-expect-failure machinery is shared with `vm_files` through
`Tests/molecule/tasks/_assert-role-rejected.yml`: the shape of that test
does not vary with the role, only the role's name and its input var names
do, and the caller supplies both. What that harness cannot do is take the
input vars as a mapping - Ansible refuses a templated dictionary as a
block's `vars` - so each scenario sets the role's own var names on the
task that includes it, which is where they belong anyway.
