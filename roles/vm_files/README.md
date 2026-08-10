# Role: vm_files

Transports operator-declared host files onto a provisioned VM.

Its input is the `files` array of a VM definition, reproduced field for
field. The estate already speaks that schema - a PowerShell engine has
owned it since before this role existed - so the two entry forms, their
sub-field names and their validation rules are ported rather than
redesigned: a definition a consumer's config already carries is valid here
unchanged, and is accepted or rejected identically whichever engine runs
it.

## Index

- [Entry contract](#entry-contract)
- [Why the role validates its own input](#why-the-role-validates-its-own-input)
- [What is deliberately not validated](#what-is-deliberately-not-validated)
- [Bulk resolution](#bulk-resolution)
- [Transport](#transport)
- [What it reports](#what-it-reports)
- [Consuming this role](#consuming-this-role)
- [Tests](#tests)

## Entry contract

Full field documentation lives in
[`defaults/main.yml`](defaults/main.yml). In brief, `vm_files_entries` is
a list of entries in one of two forms, discriminated by the presence of
`pattern`:

| Form | Sub-fields | Meaning |
| --- | --- | --- |
| Single | `source`, `target` | One named controller-side file, copied to one absolute path on the VM |
| Bulk | `pattern`, `targetDir`, optional `recurse`, optional `preserveRelativePath` | Every controller-side file matching an absolute glob, copied under one absolute directory on the VM |

Sub-fields are camelCase because they are config keys parsed out of the VM
definition JSON, not Ansible variables.

Source paths are POSIX and name files on the controller. A Windows-hosted estate
translates its drive letters *before* dispatch, which is what keeps this
role free of any host-topology knowledge and testable in a plain
container.

Both optional bulk flags default to `false`: matching stays shallow, and
matches flatten to their basename under `targetDir`.

## Why the role validates its own input

The role is a provisioning vector in its own right, not a downstream stage
of some other engine's pre-pass. It cannot assume any validation has
already run, so it performs its own - and performs it before the first
byte crosses the connection, so a rejected run leaves the target exactly
as it found it rather than half-copied.

Unknown sub-fields are rejected. Strictness is deliberate and matches
every other field of the VM schema: a silently-ignored `targetdir` typo
would hand the operator a run that reported success and copied nothing,
which is the one failure mode a file-transport step must never have.

Every rejection names the offending entry by position and by host, because
"must be a mapping" on its own does not tell an operator which of a dozen
entries in which VM definition to go and fix.

The task layout mirrors the PowerShell original for the reason it is split
there too - the two forms evolve independently:

| File | Owns |
| --- | --- |
| [`tasks/main.yml`](tasks/main.yml) | The list-shaped container, the per-entry loop, then resolution and transport |
| [`tasks/_assert-entry.yml`](tasks/_assert-entry.yml) | Checks shared by both forms, and the discrimination between them |
| [`tasks/_assert-single-entry.yml`](tasks/_assert-single-entry.yml) | Single-form rules |
| [`tasks/_assert-bulk-entry.yml`](tasks/_assert-bulk-entry.yml) | Bulk-form rules |
| [`tasks/_resolve-bulk-entry.yml`](tasks/_resolve-bulk-entry.yml) | Expanding one glob into source/target pairs |
| [`tasks/_copy-resolved-files.yml`](tasks/_copy-resolved-files.yml) | The transport, shared by both forms |
| [`tasks/_record-report.yml`](tasks/_record-report.yml) | Projecting what the transport did into the files report |

The allow-lists the unknown-sub-field rules read live in
[`vars/main.yml`](vars/main.yml), not `defaults/`, precisely so a consumer
cannot widen one locally and fork the schema.

## What is deliberately not validated

- **That a `source` exists.** It lives on the controller while the play
  runs against the target, so checking it means a delegated probe per
  entry - to answer a question the transport answers authoritatively
  anyway, and without pretending a file present at validation time is
  still present a minute later.
- **That a `pattern` matches anything.** A glob is time-varying; the
  resolution the transport performs is the only one whose answer is still
  true when the files are read. A pattern naming nothing is still a hard
  failure - it just happens one step later, in
  [bulk resolution](#bulk-resolution). What validation does check is that
  the pattern is one this engine can resolve at all.

## Bulk resolution

A bulk entry is expanded on the **controller**, where the sources live,
and the pairs it produces go to the same transport the single form uses.
Expansion happens at transport time rather than at validation time
because a glob is time-varying: the only resolution whose answer is still
true when the bytes are read is the one the transport is about to act on.

The rules are ported from the PowerShell engine's resolver, so a pattern
names the same files and lands them on the same VM paths whichever engine
runs it:

| Rule | Behaviour |
| --- | --- |
| Anchor | The search starts at the longest run of leading path components carrying no wildcard, cut at a **component boundary**: `/src/foo*/x` anchors at `/src`, never at `/src/foo` |
| Directories | Dropped at the source, so a pattern matching only directories reaches the zero-match failure rather than copying one |
| Zero matches | A hard failure naming the pattern. The entry was declared because those files are expected on the VM, so copying none of them and reporting success is not an outcome |
| `preserveRelativePath: false` | Every match flattens to `targetDir/<basename>` |
| `preserveRelativePath: true` | Every match keeps its path relative to the anchor, mirrored under `targetDir` |
| `recurse` | Widens the filename half of the pattern to any depth below its container, matching `Get-ChildItem -Recurse` |
| Collisions | Two matches claiming one VM path is a hard failure. Left undetected the second copy would silently overwrite the first, in either mode - flatten-mode basename collisions across sub-directories, and preserve-mode collapses, surface the same way |

Matching is one expression applied to whole paths. Ansible's `find` is
used purely to enumerate candidates, rather than being handed the
filename half of the job through its own globbing: two matchers that have
to agree are two matchers that can disagree, and `find` cannot express
the container half of a pattern (`foo*/x`) anyway.

Two constraints this engine adds, both refusals where the alternative
would be a **silent** divergence - a definition that copies one set of
files under one engine and a different set under the other:

- **The pattern must be absolute.** A relative one resolves against the
  controller's working directory, which is chosen by whichever bridge
  launched the play, so an operator's config cannot mean anything stable
  by it.
- **Character classes (`[ab].jar`) are refused.** PowerShell expands
  them; this engine does not. Left alone the pattern would still match
  *something* here - a file genuinely named `[ab].jar` - so it is
  rejected outright. Supported wildcards are `*` and `?`, neither of
  which crosses a path component.

Matches are sorted, so the order files are copied in - and reported in -
is the same on every run and on every controller rather than whatever
order the filesystem walk produced.

## Transport

Validation done, the role resolves every declared entry into a flat list
of source/target pairs and hands that one list to a single transport. The
two forms differ only in how many pairs each produces - the single form is
already a pair, a bulk one expands to many - so resolution is per form and
transport is not. That is what keeps the ownership policy from being
stated twice and drifting.

Each file is copied with `ansible.builtin.copy`, which means the bytes
travel inside the connection the play is already using; no listener is
opened on the host and nothing is published on the network for the
duration of a run.

Files land **root-owned and `0644`**, and directories the role creates
land **root-owned and `0755`**. Both are stated on the task rather than
inherited from the source. Whatever attributes a file carries on the
controller are an accident of how it got there - a checkout, a download,
a Windows volume with no POSIX modes at all - and none of that should
decide what the VM ends up with. User-owned content is out of scope: it
belongs to the users layer, which runs once the users it would be owned
by actually exist.

Both policies are named in [`vars/main.yml`](vars/main.yml) rather than
written on the tasks, because [the report](#what-it-reports) quotes them:
an operator reading `root:root 0644` off the report is reading the same
values the transport applied, so the report cannot claim a policy the role
does not enforce. They live in `vars/` for the same reason the schema lists
do - the policy is an invariant consumers rely on, so a caller must not be
able to relax it for one host.

A missing parent directory is created, including intermediate levels. It
is created only where one is genuinely **absent** - the role stats first
rather than declaring the directory outright, because a
`file: state=directory` carrying owner and mode reasserts them on a
directory that already exists, and an entry targeting (say) a home
directory would then silently chown it to root. Creating what is missing
and touching nothing else keeps the role's writes confined to the files
it was asked to copy.

## What it reports

The role appends one entry to the play-wide `files_report_entries`
accumulator per **file that landed** - not per declared entry, because a
bulk entry's whole point is that one line of config becomes an unknown
number of files. [`files_report`](../files_report/README.md) renders that
accumulator once per host, and owns the entry contract.

Each entry carries the file's source, the VM path it landed on, the
ownership the transport applied, whether this run wrote it
(`copied`/`unchanged`), and - for a matched file - the pattern that named
it. Two of those are only knowable here:

- **`copied` vs `unchanged`** comes from the `copy` result's `changed`
  flag. That is the one moment the two cases are distinguishable; a scan of
  the finished VM sees the file either way.
- **Which files a glob expanded to, and what each was named** is visible
  only in the run. A target carrying `v1/` where the pattern carried `v*`
  appears nowhere in the config, and the PowerShell engine never printed
  it.

Recording is its own task file rather than part of the transport because it
is a different concern: what lands, and what an operator is told about it.

## Consuming this role

```yaml
- name: Copy the declared files onto this VM
  ansible.builtin.include_role:
    name: vm_files
  vars:
    vm_files_entries:
      - source: /mnt/c/estate/app.conf
        target: /etc/app/app.conf
      - pattern: /mnt/c/estate/jars/*.jar
        targetDir: /opt/app/lib
```

With no `vm_files_entries` the role is a no-op, so a play can always
include it and let config decide whether there is anything to copy.

Close the play with [`files_report`](../files_report/README.md) to print
what was transported.

## Tests

`Tests/molecule/vm_files/default` covers the single form transport. Its
fixtures are staged on the controller mode `0600` and owned by whoever
runs the scenario, so the verifier's `root:root 0644` assertions prove the
policy is applied rather than merely inherited. One entry per case:

| Case | What it pins down |
| --- | --- |
| Parents must be created | Both created levels are `root:root 0755` |
| Parent already exists | The directory - deliberately neither root-owned nor `0755` - is left exactly as it was found |
| Target already exists, drifted | Wrong content, owner and mode are all reconciled, so the transport is not merely a create |
| No entries declared | The no-op promise above holds, rather than tripping over an empty loop's register, and contributes nothing to the report |

Its converge also asserts the report accumulator: one entry per copied
file, each carrying the target and source it was declared with, no pattern
(these were named outright), and the ownership the verifier independently
reads back off the VM - so the two together prove the report describes what
actually landed.

`molecule idempotence` covers the re-run.

`Tests/molecule/vm_files/bulk` covers resolution. One controller-side
fixture tree is built in `prepare.yml` and every case is a different
subset cut out of it - a per-case tree holding only the expected matches
would prove nothing about what a pattern leaves behind:

| Case | What it pins down |
| --- | --- |
| Flatten, shallow | Only the extension asked for, only the top level, and a trailing separator on `targetDir` tolerated |
| Flatten, recursive | Basenames from two different depths land side by side |
| Preserve, recursive | The same match set mirrors its sub-tree instead, so the flag is the only difference between the two targets |
| Wildcard mid-pattern | The anchor is the component boundary: `variants/v*/config.ini` lands `v1/...` and `v2/...`, not `1/...` and `2/...` |
| `?` in a pattern | Exactly one character - `?.json` leaves behind what `*.json` takes |
| Dot-prefixed source | Matched like any other name, which is what the PowerShell engine does on a Windows volume |
| Files and directories matched | The directories are dropped, so exactly the files land |
| A single form entry among them | Both forms feed one accumulator, so resolving a bulk entry must add to it rather than replace it |
| Pattern matching nothing | Refused, naming the pattern |
| Pattern matching only directories | Refused the same way, rather than copying a directory or succeeding empty |
| Two matches, one VM path | Refused, naming the contested path and pointing at `preserveRelativePath` |

Every case asserts the bytes at each destination, not merely a file of
the right name: two matches landing on one target, or a match landing
under the wrong entry's `targetDir`, both produce a plausible-looking
file. The paths a pattern must **not** have selected are asserted absent
too, since a resolver that matched too generously satisfies every
presence assertion ever written. `molecule idempotence` covers the
re-run, which for this scenario also means the expansion is stable.

Its converge asserts the report accounts for every resolved file - one
entry per matched file with its VM path, every declared glob represented,
and the single form entry among them carrying no pattern - and then renders
the report from that accumulator. Rendering it here is what makes the
producer and the template meet on real data:
[`Tests/molecule/files_report`](../files_report/README.md#tests) seeds its
entries by hand, so a field this role stopped emitting would pass there and
surface only in front of an operator.

It also makes the one rendering claim only this fixture can make: two of its
entries share a glob with different `targetDir`s, so the report must merge
them into a single pattern group carrying both landings.

Both accumulator assertions treat `copied`/`unchanged` as a domain rather
than pinning a value, because `molecule idempotence` re-runs the same
converge against an already-converged VM. The values themselves are pinned
in the `files_report` scenario, whose entries are seeded rather than
produced.

The refusals reuse the schema scenario's helper: whether an entry is
rejected by a shape rule or by a pattern that resolves to nothing, the
run must fail and the failure must name what an operator has to go and
fix.

`Tests/molecule/vm_files/schema` covers the contract from both sides. Its
`converge.yml` is the positive control - a well-formed entry set using
both forms and every optional sub-field is accepted - and `verify.yml`
runs the rejection matrix, one case per rule, each a minimal mutation of a
shape the converge accepts.

Every rejection case applies the real role and asserts on the message it
produced, so the matrix cannot drift into agreeing with a broken role. The
cases assert the diagnostic too, not merely that something failed: a
rejection that does not name the violated rule and the offending entry's
position fails the test.
