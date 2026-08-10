# Role: vm_files

Transports operator-declared host files onto a provisioned VM.

Its input is the `files` array of a VM definition, reproduced field for
field. The estate already speaks that schema - a PowerShell engine has
owned it since before this role existed - so the two entry forms, their
sub-field names and their validation rules are ported rather than
redesigned: a definition a consumer's config already carries is valid here
unchanged, and is accepted or rejected identically whichever engine runs
it.

**TODO: transport.** What the role owns today is the contract and its
validation - it copies nothing yet, so a play including it reconciles no
files. The sections below describe the contract, which is complete; the
[consuming example](#consuming-this-role) declares what will be
transported rather than what is transported today.

## Index

- [Entry contract](#entry-contract)
- [Why the role validates its own input](#why-the-role-validates-its-own-input)
- [What is deliberately not validated](#what-is-deliberately-not-validated)
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
| Bulk | `pattern`, `targetDir`, optional `recurse`, optional `preserveRelativePath` | Every controller-side file matching a glob, copied under one absolute directory on the VM |

Sub-fields are camelCase because they are config keys parsed out of the VM
definition JSON, not Ansible variables.

Paths are POSIX and controller-relative. A Windows-hosted estate
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
| [`tasks/main.yml`](tasks/main.yml) | The list-shaped container, then the per-entry loop |
| [`tasks/_assert-entry.yml`](tasks/_assert-entry.yml) | Checks shared by both forms, and the discrimination between them |
| [`tasks/_assert-single-entry.yml`](tasks/_assert-single-entry.yml) | Single-form rules |
| [`tasks/_assert-bulk-entry.yml`](tasks/_assert-bulk-entry.yml) | Bulk-form rules |

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
  true when the files are read.

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

## Tests

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
