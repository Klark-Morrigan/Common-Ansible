# Role: report_render

The shared tail of every operator-facing report in this repo. A report
role renders its own text - it owns its template and its entry contract -
and delegates here to get that text in front of an operator and into an
assertable fact.

It installs nothing and knows nothing about any particular report.

## Index

- [Why it exists](#why-it-exists)
- [Var contract](#var-contract)
- [Why the caller does the lookup](#why-the-caller-does-the-lookup)
- [Consuming this role](#consuming-this-role)
- [Tests](#tests)

## Why it exists

Printing a multi-line report through Ansible has three non-obvious
mechanics, none of which is about the report's content. Stated once here,
they stay stated once no matter how many reports exist:

1. **`splitlines()`, not `| split('\n')`.** The backslash-n in a Jinja
   string literal does not reach the filter as a newline through Ansible's
   templating, so the filter form silently returns the whole report as a
   single element - which renders as one unreadable row. `splitlines()`
   needs no escape at all.
2. **A list of lines, not one newline-joined string.** The default
   callback JSON-encodes a `debug` msg, so a multi-line string renders as
   an unreadable `"line1\nline2\n..."` blob on a single row; a list prints
   one element per row.
3. **`trim` before splitting.** A template ends with a newline, which
   would otherwise become a trailing empty line.

The rendered text is also left behind as a fact, so a test - or any
consumer wanting the report as data rather than as stdout - asserts on the
same value the operator saw instead of scraping the callback.

Three roles delegate here today:
[`toolchain_report`](../toolchain_report/README.md),
[`artifact_report`](../artifact_report/README.md) and
[`files_report`](../files_report/README.md).

## Var contract

Full field documentation lives in
[`defaults/main.yml`](defaults/main.yml). In brief:

- `report_render_text` - the fully rendered report, as one string.
- `report_render_fact` - name of the fact to leave the split lines in
  (e.g. `toolchain_report_lines`). The caller owns this name because the
  caller owns the contract its tests and consumers read. The fact name is
  templated into `set_fact`'s key, which is what lets one role serve every
  report while each keeps its own documented output.
- `report_render_label` - trailing phrase for the printing task's name,
  rendered as `Report the <label>`, so a play running several reports is
  readable in the task list. It carries the whole trailing phrase rather
  than just a noun because ansible-lint's `name[template]` rule requires
  the interpolation to sit at the end of the name.

## Why the caller does the lookup

The caller performs its own `lookup('ansible.builtin.template', ...)` and
passes the **result**, rather than passing a template name for this role
to look up.

Doing it the other way would make template resolution depend on
`ansible_search_path` containing the calling role - true in practice, but a
subtlety that would bite the moment two report roles carried
similarly-named templates. Three of them exist now, each with its own
`*-report.j2`. Passing text keeps the boundary blunt: this role never
resolves a path and never needs to know a template exists.

## Consuming this role

```yaml
- name: Render and print the toolchain report
  ansible.builtin.include_role:
    name: report_render
  vars:
    report_render_text: >-
      {{ lookup('ansible.builtin.template', 'toolchain-report.j2') }}
    report_render_fact: toolchain_report_lines
    report_render_label: reconciled toolchains for this host
```

`include_role` (not `import_role`) so the `vars` above - including the
lookup - evaluate in the calling role's scope at runtime.

## Tests

No scenario of its own: this role has no behaviour independent of a
report. It is covered end to end by the scenario of each report that
delegates here - `Tests/molecule/toolchain_report/default`,
`Tests/molecule/artifact_report/default` and
`Tests/molecule/files_report/default` - whose `verify.yml` asserts the line
list this role produces, including that no blank or whitespace-only lines
survive the split, which is the failure mode all three mechanics above
exist to prevent.
