# Role: dotnet_tools

Installs, swaps, and uninstalls .NET **global tools** on the target via the
`dotnet tool` driver, recording each install as a manifest so removal is
glob-free. It is the nested global-tools half of the .NET toolchain; the SDK
half is the sibling [`dotnet_sdk`](../dotnet_sdk/README.md) role. Ports the
PowerShell reconciler's `DotnetToolsProvider`
(`Infrastructure-Vm-Provisioner` `up/dotnet`); see
[the plan](../../docs/dev/implementation/19-common-ansible-extraction-and-toolchain-provisioning/plan.md#step-54---dotnet_tools-role-nested-under-sdk).

## Index

- [Var contract](#var-contract)
- [Relationship to the SDK role](#relationship-to-the-sdk-role)
- [Parent/child teardown ordering](#parentchild-teardown-ordering)
- [How it installs a tool](#how-it-installs-a-tool)
- [How it uninstalls a tool](#how-it-uninstalls-a-tool)
- [Consuming this role](#consuming-this-role)
- [Tests](#tests)
- [Parity with the PowerShell reconciler](#parity-with-the-powershell-reconciler)

## Var contract

Full field documentation lives in
[`defaults/main.yml`](defaults/main.yml). In brief:

- `dotnet_tools_tools` (default `[]`) - the desired global-tool entries.
  Each is an `{id, version}` mapping: `id` is the NuGet package id (e.g.
  `dotnet-reportgenerator-globaltool`), `version` the exact NuGet version.
  Empty uninstalls every tool this role has a manifest for. The diff keys on
  the composite `<id>@<version>` (two tools may share a NuGet version).
- `dotnet_tools_root` (default `/usr/local/share/dotnet/tools`) - the
  `--tool-path`. **Must equal** the SDK role's `dotnet_sdk_tools_root`,
  which wires this dir onto `PATH` in the single `/etc/profile.d/dotnet.sh`.
- `dotnet_tools_dotnet_bin` (default `/usr/local/bin/dotnet`) - the driver
  the tool operations run, the symlink the SDK role creates.
- `dotnet_tools_manifest_dir` (default
  `/var/lib/common-ansible/toolchains/manifests`) - the shared manifest
  store; tool manifests are `dotnettool-<id>-<version>.json` (no glob
  collision with the SDK's `dotnet-*.json`).
- `dotnet_tools_staging_base` (default
  `/var/lib/common-ansible/toolchains/dotnet-tool-staging`) - per-tool
  `.nupkg` + `NuGet.Config` staging root, wiped after each install.
- `host_file_server_base_url` (bridge-supplied, required when installing) -
  the substrate file server the `.nupkg` is pulled from, at
  `<base>/dotnet-tool-<id>-<version>.nupkg`.

## Relationship to the SDK role

Unlike `jdk` / `dotnet_sdk`, this role does **not** build on
[`toolchain_host_push`](../toolchain_host_push/README.md): a global tool is
a NuGet package installed by the `dotnet tool` driver, not a tarball
extracted to `/opt`. What the two share is the manifest-driven
desired-vs-installed reconcile (read manifests -> stale/missing diff ->
uninstall-stale-then-install-missing), which this role **mirrors** rather
than delegates, because the install/uninstall mechanics differ entirely.

The two roles are otherwise decoupled: the SDK owns
`/etc/profile.d/dotnet.sh` (including the tools dir on `PATH`) and the
`dotnet` driver; this role owns only the tools it installs and their
`/usr/local/bin` shim symlinks. There is deliberately **no** meta dependency
between them - the consumer play composes the pair (see below).

## Parent/child teardown ordering

Every `dotnet tool` operation - install **and uninstall** - needs the
`dotnet` driver on `PATH`, which `dotnet_sdk` provides via
`/usr/local/bin/dotnet`. So a consumer play must:

- **install/steady state:** run `dotnet_sdk` (or ensure the SDK is present)
  **before** `dotnet_tools`, so the driver exists when a tool installs;
- **teardown:** run `dotnet_tools` **before** `dotnet_sdk`, so the driver is
  still present when the tools uninstall. Remove the SDK first and
  `dotnet tool uninstall` cannot run - the tool's `.store` slot would leak.

This role-order contract is the Ansible expression of the parent/child
teardown ordering the PowerShell reconciler's children-walker guaranteed
(tools are removed before the SDK). The consumer flow (plan step 5.5) owns
placing the roles in this order.

```mermaid
flowchart LR
  subgraph install [install / steady state]
    S1[dotnet_sdk] --> T1[dotnet_tools]
  end
  subgraph teardown
    T2[dotnet_tools] -. removed before .-> S2[dotnet_sdk]
  end
```

## How it installs a tool

For each desired tool with no manifest
([`tasks/_install-tool.yml`](tasks/_install-tool.yml)):

1. Pull the `.nupkg` from `host_file_server_base_url` into a per-tool
   staging dir, under NuGet's flat-layout name `<id-lower>.<version>.nupkg`
   (the SDK local-source enumerator matches on that pattern).
2. Write a `NuGet.Config` there that `<clear />`s ambient sources and
   declares the staging dir as the sole source, so `--configfile` keeps the
   resolver offline.
3. `dotnet tool install <id> --tool-path <root> --configfile <cfg>
   --version <version>`.
4. Discover the command shim(s) the driver added by diffing the tool-path
   file listing before vs after the install (layout-independent, per-tool
   correct even with other tools present), and symlink each into
   `/usr/local/bin`.
5. Write the manifest **last** (crash-recovery anchor), recording the id,
   version, composite key, store dir, shim symlinks, and command names.
6. Wipe the staging dir (best-effort).

## How it uninstalls a tool

For each installed tool no longer desired
([`tasks/_uninstall-tool.yml`](tasks/_uninstall-tool.yml)), inverted from
install and driven by the manifest:

1. Remove the recorded `/usr/local/bin` shim symlinks (exactly the recorded
   paths - never a glob).
2. `dotnet tool uninstall <id> --tool-path <root>` to free the `.store`
   slot. Non-zero is logged, not fatal (a stale slot must not block manifest
   removal). The role never `rm`s `.store/` itself - the driver owns that
   slot.
3. Remove the manifest **last** (recovery anchor).

## Consuming this role

```yaml
# SDK first so the driver exists, then the tools.
- name: Install the .NET SDK and its global tools
  hosts: builders
  tasks:
    - name: .NET SDK
      ansible.builtin.include_role:
        name: dotnet_sdk
      vars:
        dotnet_sdk_versions:
          - channel: "10.0"
            version: "10"

    - name: .NET global tools
      ansible.builtin.include_role:
        name: dotnet_tools
      vars:
        dotnet_tools_tools:
          - id: dotnet-reportgenerator-globaltool
            version: "5.4.4"
```

`host_file_server_base_url` must be supplied by the bridge, and each tool's
`.nupkg` must be staged on that file server as
`dotnet-tool-<id>-<version>.nupkg` (the acquisition/staging step, plan 5.5).
On teardown, list `dotnet_tools` (with an empty desired set) **before**
`dotnet_sdk` - see [Parent/child teardown ordering](#parentchild-teardown-ordering).

## Tests

[`Tests/molecule/dotnet_tools/`](../../Tests/molecule/dotnet_tools/) drives a
tool-capable `dotnet` stub (staged as a fake SDK and installed via the real
`dotnet_sdk` role, so the driver, profile, and tools `PATH` are wired
exactly as production) served together with fake `.nupkg` packages from one
`127.0.0.1` http fixture:

- **default** - with the SDK present, install a tool, then
  `molecule idempotence`. Verifies the `.store` slot, the `/usr/local/bin`
  shim symlink, the manifest (id, version, key, symlinks, commands), and
  that the symlinked command runs.
- **remove** - install the SDK and a tool, then converge `dotnet_tools`
  (empty desired set) **before** `dotnet_sdk` (empty desired set). Verifies
  the tool is fully removed (shim, `.store` slot, manifest) **and** the SDK
  is removed - proving the tool was torn down while the driver was still
  present. A reversed order would leak the `.store` slot, which the verify
  would catch.

## Parity with the PowerShell reconciler

The composite `<id>@<version>` diff identity, the offline `--configfile`
install from a pinned local source, the driver-owned `.store` slot freed by
`dotnet tool uninstall` (never a direct `rm`), the per-command
`/usr/local/bin` shim symlinks recorded for glob-free removal, and the
manifest-last ordering all mirror `DotnetToolsProvider`. The parent/child
teardown ordering the PowerShell children-walker enforced at reconcile time
is expressed here as the consumer play's role order (tools before the SDK on
teardown). The `.nupkg` acquisition + checksum verification is the
consumer/staging step's concern (plan 5.5), not this role's - the same
acquire/install split the reconciler drew.
