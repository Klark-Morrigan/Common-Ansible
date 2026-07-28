# Role: powershell

Installs **PowerShell** (`pwsh`) from Microsoft's self-contained Linux
release tarball, delegating the install / swap / uninstall mechanics to the
section-1 host-push pattern
([`toolchain_host_push`](../toolchain_host_push/README.md)). It is the
third consumer of that pattern, alongside
[`jdk`](../jdk/README.md) and [`dotnet_sdk`](../dotnet_sdk/README.md).

## Index

- [Why this role exists](#why-this-role-exists)
- [Var contract](#var-contract)
- [Why there is no resolver](#why-there-is-no-resolver)
- [What the install lays down](#what-the-install-lays-down)
- [Runtime smoke check](#runtime-smoke-check)
- [Consuming this role](#consuming-this-role)
- [Tests](#tests)

## Why this role exists

CI composite actions that declare `shell: pwsh` need the interpreter
present on the runner. A self-hosted runner image without it fails with a
bare `pwsh: command not found` at the first step that runs a shell -
before any toolchain preflight can report something more useful, because
those preflights are themselves written in PowerShell. Baking `pwsh` into
the image alongside the .NET SDK closes that gap.

## Var contract

Full field documentation lives in
[`defaults/main.yml`](defaults/main.yml). In brief:

- `powershell_versions` (default `[]`) - the desired versions, each an
  **exact** `<major>.<minor>.<patch>` string (e.g. `7.6.4`). Empty
  uninstalls every version this role has installed. At most one entry in
  v1; a longer list is a hard error.
- `powershell_architecture` (default `x64`) - spliced into the archive
  name; `arm64` is the other value Microsoft publishes.
- `powershell_install_base` (default `/opt`) - forwarded to
  `toolchain_host_push` as the install-dir base.
- `powershell_verify_runtime` (default `true`) - run the
  [smoke check](#runtime-smoke-check) after install.
- `host_file_server_base_url` (bridge-supplied, required when installing)
  - the substrate file server the tarball is pulled from, at
  `<base>/powershell-<version>-linux-<arch>.tar.gz`.

## Why there is no resolver

`jdk` and `dotnet_sdk` each carry a `_resolve-*.yml` that queries an
upstream feed, because neither can derive its archive name from an
operator's pin - Adoptium's name embeds a build number, and Microsoft's
.NET feed publishes a version-less asset name whose only versioned form
is the download URL's leaf.

PowerShell has no such problem. The release asset name is a pure function
of the version:

```text
powershell-<version>-linux-<arch>.tar.gz
```

So this role composes the name and asserts the version is exact. Adding a
resolver would buy nothing and cost a rate-limited `api.github.com`
dependency on every target, on every reconcile.

Loose pins are still supported - one layer up. The deploying consumer
resolves `7.6` to a concrete `7.6.4` **once, host-side**, while it
downloads and checksum-verifies the tarball into the served directory, and
hands this role the concrete version. That is the same division of labour
[`dotnet_tools`](../dotnet_tools/README.md) uses, and the same reason: the
integrity gate belongs with whoever owns the estate's egress.

## What the install lays down

The composed `toolchain_host_push` entry, and why each field is what it is:

| Field | Value | Why |
| --- | --- | --- |
| `archive` | `powershell-<v>-linux-<arch>.tar.gz` | Microsoft's asset name, which is also the name the consumer stages it under |
| `strip_components` | `0` | The tarball lays `pwsh` and its assemblies at the archive root, like the .NET SDK - not in a wrapper dir like Adoptium's |
| `symlinks` | `pwsh` -> `<install_dir>/pwsh` | Everything dispatches through the one host, so no per-launcher enumeration as for the JDK. The tarball already ships `pwsh` mode `0755`, so the extract needs no exec-bit fixup |
| `profile` | telemetry + update-check opt-outs | The unattended-runner posture, mirroring `dotnet_sdk`'s `DOTNET_CLI_TELEMETRY_OPTOUT` |
| `owned_files` | *(omitted)* | PowerShell needs no fixed config file outside its install dir - there is no equivalent of .NET's `/etc/dotnet/install_location` |

Net result for `powershell_versions: ["7.6.4"]`:

```text
/opt/powershell-7.6.4/pwsh            extracted install
/usr/local/bin/pwsh -> ...            non-login-shell PATH
/etc/profile.d/powershell.sh          login-shell env
/var/lib/common-ansible/toolchains/manifests/powershell-7.6.4.json
```

**Scope of the profile script:** `/etc/profile.d` is read by login shells
only. A CI step's `shell: pwsh` is not a login shell, so the opt-outs do
not reach it. A runner that wants them in its job environment sets them in
its own service environment - that is the consuming layer's concern, not
this role's.

## Runtime smoke check

After the install, the role runs the symlinked `pwsh` and asserts it
reports the version just installed. This covers the one failure mode no
file-level check can see: an interpreter that extracted and symlinked
perfectly but will not **start**, almost always because a native
prerequisite is missing (`libicu` above all others).

Catching that at provision time is the whole point. The alternative is a
runner that provisions "successfully" and then breaks a CI job later with
an error that points nowhere near the image.

The two steps are deliberately separate: the `command` runs without an
assertion attached so a non-zero exit surfaces the interpreter's own
stderr (the missing-library message), and only then does a second task
compare the version string. Folding them together would mask the useful
diagnostic behind a mismatch message.

Set `powershell_verify_runtime: false` only where executing the
interpreter is impossible - e.g. a cross-architecture staging host.

## Consuming this role

```yaml
- name: Reconcile the PowerShell toolchain
  ansible.builtin.import_role:
    name: powershell
  vars:
    powershell_versions:
      - "7.6.4"
```

Native prerequisites (`libicu` and friends) are **not** installed here.
They are ordinary apt packages, so they belong in the consumer's
section-2 declaration, which
[`toolchain_apt`](../toolchain_apt/README.md) reconciles. This role
asserts the result instead of installing the cause - the same boundary
`toolchain_host_push` draws everywhere else: one role, one mechanism.

## Tests

[`Tests/molecule/powershell/`](../../Tests/molecule/powershell/) covers
the three directions across three scenarios, each driven by an
in-container fixture file server
([`tasks/_fixture-powershell.yml`](../../Tests/molecule/powershell/tasks/_fixture-powershell.yml)
builds flat fake tarballs carrying a `pwsh` stub and serves them on
`127.0.0.1`):

- **default** - install one version, then `molecule idempotence`.
  Verifies the flat extract, the symlink target, the profile opt-outs,
  the manifest content, and that the smoke check ran against the
  symlinked stub. Its verify also re-applies the role with each
  non-exact pin (`7`, `7.6`, `v7.6.4`, `7.6.4-preview.1`) and asserts the
  role refuses, so the
  [exact-version contract](#why-there-is-no-resolver) is tested against
  the real role rather than asserted about it. That check lives in verify
  rather than converge because the role fails at its first assert, before
  any task that could change state - so it cannot perturb the idempotence
  run.
- **reconcile** - prepare installs `v1`, converge desires `v2` (version
  swap). Verifies `v1` is fully gone and `v2` is active.
- **remove** - prepare installs `v1`, converge desires `[]`. Verifies
  every `v1` artefact is gone and that the smoke check was skipped
  rather than run against a removed interpreter.
