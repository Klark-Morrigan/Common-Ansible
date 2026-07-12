# Common-Ansible

Ansible controller substrate - a PowerShell -> WSL dispatch bridge and
reusable roles - run against provisioned VMs. Invoked from Windows via the
bridge, which reads configuration from PowerShell SecretManagement vaults
and dispatches to `ansible-playbook` inside a Linux venv. Consumer repos
reuse the substrate to own their own domains (see
[Consuming the substrate](#consuming-the-substrate)).

Design history and rationale live under
[docs/dev/implementation/](docs/dev/implementation/); each section below
was extended by the feature step that earned it.

## Index

- [Controller bootstrap](#controller-bootstrap)
  - [Consumer controller bootstrap](#consumer-controller-bootstrap)
  - [Troubleshooting: WSL default distro has no bash](#troubleshooting-wsl-default-distro-has-no-bash)
  - [Troubleshooting: capturing logs and re-running an interrupted bootstrap](#troubleshooting-capturing-logs-and-re-running-an-interrupted-bootstrap)
- [Bridge contract](#bridge-contract)
  - [The toolchains taxonomy block (vm_provisioner_config.toolchains)](#the-toolchains-taxonomy-block-vm_provisioner_configtoolchains)
- [Reusable roles](#reusable-roles)
  - [Host-push toolchain pattern (toolchain_host_push)](#host-push-toolchain-pattern-toolchain_host_push)
  - [JDK (jdk)](#jdk-jdk)
  - [.NET SDK (dotnet_sdk)](#net-sdk-dotnet_sdk)
  - [.NET global tools (dotnet_tools)](#net-global-tools-dotnet_tools)
  - [Section-2 apt toolchain pattern (toolchain_apt)](#section-2-apt-toolchain-pattern-toolchain_apt)
  - [Section-3 Docker daemon (docker)](#section-3-docker-daemon-docker)
- [Tests and lint](#tests-and-lint)
- [Consuming the substrate](#consuming-the-substrate)
- [Feature folders](#feature-folders)

## Controller bootstrap

A fresh Windows host reaches the runnable state in one command:

```
pwsh ./ops/bootstrap-controller.ps1
```

or double-click
[`ops/bootstrap-controller.bat`](ops/bootstrap-controller.bat)
from Explorer (thin launcher: invokes `pwsh` against the `.ps1` and
holds the window open).

The PowerShell stage installs `Common.PowerShell` and
`Infrastructure.Secrets` from PSGallery (idempotent — `Invoke-ModuleInstall`
no-ops when current), ensures WSL2 is installed (delegating to
`Assert-Wsl2Ready` from `Common.PowerShell`), verifies the default WSL
distro actually has `bash` (delegating to `Assert-WslHasBash`), and
then invokes
[`ops/_bootstrap-controller-wsl.sh`](ops/_bootstrap-controller-wsl.sh)
inside WSL to create the Python venv, install the controller toolchain
(`ansible-core` plus `ansible-lint`) from `requirements.txt`, and pull
the Galaxy collections pinned in `requirements.yml`. Both stages are
idempotent.

`requirements.txt` is a hash-locked lockfile compiled by `pip-compile`
from the human-edited [`requirements.in`](requirements.in); the bootstrap
installs it with `pip install --require-hashes`, so the full transitive
closure is frozen and a drifted or unhashed line fails loudly. After
editing `requirements.in`, regenerate the lock with
`pip-compile --generate-hashes requirements.in`.

When `python3` (plus `python3-venv`) or `jq` is absent the bash
stage installs the missing package via `sudo apt-get`; the existing
`sudo apt-get install -y <pkg>` hint stays as the fallback path for
when the install itself cannot proceed (no `sudo`, `apt-get` missing,
offline, apt lock).

### Consumer controller bootstrap

Substrate consumers (Vm-Provisioner, Vm-Users, GitHubRunners) do not repeat
this logic. Each ships a ~4-line `ops/bootstrap-controller.sh` shim that
resolves this sibling and execs the shared
[`ops/bootstrap-controller-consumer.sh`](ops/bootstrap-controller-consumer.sh),
the single source of truth for the consumer side. It reuses the controller venv
that `bootstrap-controller.ps1` (above) builds, delegating to that bootstrap
only when the venv is absent, and then reports how the consumer's roles resolve
on `ANSIBLE_ROLES_PATH` (a consumer's own `roles/` ahead of the substrate's, or
substrate-only when it ships none). It takes the consumer's Ansible-slice root
as its one argument.

The `sudo` call **prompts for the WSL user's password once per fresh
bootstrap** (the very first user you set when WSL provisioned the
distro). Three ways to deal with it depending on how often a fresh
bootstrap will happen:

- **Type the password** at the prompt. Once per workstation in
  practice (the install is idempotent; re-bootstrapping a healthy
  workstation skips the `sudo apt-get` branch entirely).
- **Pre-install the three packages once**, then bootstrap is
  fully unattended:

  ```
  wsl -d Ubuntu-24.04 -- sudo apt-get update
  wsl -d Ubuntu-24.04 -- sudo apt-get install -y python3 python3-venv jq
  ```

- **Add a scoped passwordless-sudo rule** inside the distro
  (`sudo visudo -f /etc/sudoers.d/passwordless-apt`,
  contents `<your-user> ALL=(ALL) NOPASSWD: /usr/bin/apt-get`).
  Bootstrap then runs unattended forever, at the cost of standing
  apt-get sudo for that user.

Once bootstrap finishes you should see `Ansible <version>` in its
summary block and a populated `.venv/` in the repo root. Until both
are true the bridge fails with `_run-playbook.sh: .venv missing -
run ops/bootstrap-controller.{ps1,sh} first` (this is the bridge
refusing to run before bootstrap, not a separate bug).

### Troubleshooting: WSL default distro has no bash

If bootstrap fails with a yellow `bash was not found on PATH inside
the default WSL distro ...` message, the workstation's default WSL
distro does not ship bash. The usual root cause is **Docker Desktop**:
its installer ships a minimal `docker-desktop` engine distro (busybox
userland, no bash) and silently makes it the WSL default, so a bare
`wsl --` call lands there and every `#!/usr/bin/env bash` script in
the bridge fails with `env: can't execute 'bash': No such file or
directory`.

Diagnose:

```
wsl --list --verbose
```

If the `*` (default) is on `docker-desktop`, that is the trap.
Remediate by installing a real distro and pinning it as default:

```
wsl --install -d Ubuntu-24.04
wsl --set-default Ubuntu-24.04
```

Re-run `ops/bootstrap-controller.ps1`; the second WSL gate now
passes and the bash bridge runs against the new default.

E2E callers (`Infrastructure-E2E/agent/Start-E2EAgent.ps1`) avoid the
trap entirely by passing `-WslDistro <name>` and storing the same
value in the `E2EConfig` vault, so they target the bash-having distro
explicitly via `wsl -d <name> --` regardless of what the workstation's
default happens to be at the time.

### Troubleshooting: capturing logs and re-running an interrupted bootstrap

When invoking the WSL stage directly (rather than via
`ops/bootstrap-controller.ps1` or the menu) it is tempting to pipe
through `tee` to capture a log:

```powershell
wsl -d Ubuntu-24.04 -- bash -lc './ops/_bootstrap-controller-wsl.sh' 2>&1 | tee bootstrap.log
```

That works **only if no sudo prompt will fire**. The pipeline
detaches stdin from the terminal; sudo cannot find a TTY to read a
password and dies with `sudo: a password is required` (or, worse,
silently no-ops the install branch and the bootstrap reports success
without actually installing anything). Two safe workarounds:

- Pre-install the apt prerequisites once (`wsl -d Ubuntu-24.04 -u root
  -- apt-get install -y python3 python3-venv jq`); subsequent
  bootstrap runs never enter the sudo branch and can be tee'd freely.
- Run bootstrap *without* `tee`, type the password at the prompt, and
  re-run with `tee` afterwards for the log (the second run skips the
  sudo branch because the packages are now present).

Note that `tee bootstrap.log` writes to the calling shell's current
directory, not the repo - so the file lands at the location PowerShell
reports in its prompt (typically `C:\Users\<you>\`), not at
`C:\a_Code\Common-Ansible\`. Look there if the log seems
to have vanished.

If a bootstrap run is interrupted (Ctrl+C, network blip during
`ansible-galaxy collection install`, sudo prompt dismissed), **just
re-run it**. Every stage is idempotent: an existing healthy `.venv`
is reused, pip pins are no-ops when current, `ansible-galaxy
--force-with-deps` re-installs cleanly over a partial extraction.
The only state worth manually clearing is a half-built `.venv` that
has `bin/python` but no `bin/pip` (left behind by the pre-fix
`python3 -m venv` bug); in that case
`rm -rf /mnt/c/a_Code/Common-Ansible/.venv` then re-run
bootstrap to recreate it cleanly.

## Bridge contract

The bash bridge between operator scripts under `ops/` and
`ansible-playbook` is split across single-purpose helpers under
`ops/` with a leading `_` (the "called by operator entries, not
typed by a human" convention). Each is unit-testable against just
its own external boundary.

The helpers that know the VM fleet's shape - inventory building, the
Hyper-V/ICS/portproxy router resolution, and the host file server -
live together under [`ops/virtual-machines/`](ops/virtual-machines/).
Grouping them keeps the estate-specific coupling (the
`vm_provisioner_config` schema, the `<Name>Config-<suffix>` secret
convention, and the Hyper-V router topology) in one named place rather
than scattered through the otherwise consumer-agnostic bridge - a
visible, contained seam for any later move toward a fully fleet-agnostic
substrate. The generic helpers (contract parse, vault read, extra-vars
compose, the orchestrator itself) stay at the `ops/` root:

- [`ops/_parse-consumer-contract.sh`](ops/_parse-consumer-contract.sh)
  - consumer contract parser. A wrapper declares what the run needs
  through `CA_*` environment variables rather than the bridge
  hardcoding any vault name or toggle; this helper normalises that
  declaration into a stable parsed form. Inputs: `CA_INVENTORY_VAULT`
  (required - the vault holding the fleet inventory, named by the
  consumer so the substrate hardcodes no vault, not even the
  inventory's; the wrappers pass `VmProvisioner`); and the optional,
  default-"none" `CA_EXTRA_VAULTS` (vault names beyond the inventory
  vault, whitespace- or comma-separated), `CA_NEEDS_HOST_FILE_SERVER`
  (`1` opts in), `CA_REQUIRES_TOKEN` (`1` declares a GitHub token is
  needed, supplied out-of-band via `GH_TOKEN`), and `CA_CONSUMER_ROOT`
  (optional path to a consumer repo that owns the playbook, roles, and
  per-domain extra-vars fragment this run dispatches; empty -> the
  bridge resolves those from its own substrate root). It emits five
  `KEY=value` lines on stdout (`INVENTORY_VAULT=`, `EXTRA_VAULTS=`,
  `NEEDS_HOST_FILE_SERVER=`, `REQUIRES_TOKEN=`, `CONSUMER_ROOT=`) and
  rejects an invalid contract - a missing required inventory vault, or a
  required token with none supplied - with a non-zero exit before any
  vault read. Keeping this parse in a single-purpose sibling is the seam
  that lets the substrate serve unknown future consumers without
  importing their identities.
- [`ops/_read-vault-config.sh`](ops/_read-vault-config.sh) - vault
  reader. Shells out to `pwsh.exe` to fetch a named secret via the
  `Infrastructure.Secrets` wrapper (`Get-InfrastructureSecret`, never
  bare `Get-Secret` — single provider-swap point per problem.md),
  strips CRLF + UTF-8 BOM, validates JSON, prints the payload on
  stdout. Only helper that talks to the Windows side.
- [`ops/virtual-machines/_build-inventory.sh`](ops/virtual-machines/_build-inventory.sh)
  - pure transform. Reads `vm_provisioner_config` on stdin and writes
  Ansible JSON inventory (group `vm_provisioner_hosts`, host key
  `vmName`) on stdout. Lives in the `ops/virtual-machines/` module with
  the rest of the VM-fleet code (see the note at the top of this
  section).
- [`ops/_build-extra-vars.sh`](ops/_build-extra-vars.sh) - extra-
  vars composer. Owns no payload domain itself, but owns the one
  convention the orchestrator must not: how a vault Name maps to its
  per-domain fragment helper. The bridge hands it the always-on
  provisioner config plus every contract-declared vault as a generic
  `--vault-config <Name>=<path>` pair; the composer derives each Name's
  helper by the `_build-extra-vars-<Name>.sh` convention, dispatches the
  vault's config to it, then merges the fragments via `jq -s add`.
  Inputs:
  - `--provisioner-config <file>` (required) — the inventory the bridge
    read from the contract-declared vault. A flag name, not a vault
    name: the composer never learns which vault it came from.
  - `--vault-config <Name>=<path>` (repeatable) — one per extra vault.
    The Name derives the helper `_build-extra-vars-<Name>.sh`; a Name
    with no such helper is a contract typo or a domain with no helper
    yet and is rejected, never silently dropped.
  - `--github-token <value>` — an optional cross-cutting input forwarded
    to every declared vault's helper when supplied (a helper that does
    not consume it never receives it). Requires at least one declared
    extra vault, since nothing consumes it otherwise; whether a given
    helper *requires* the token is that helper's own contract, not the
    composer's.
  - `--host-base-url <url>` + `--runner-version <ver>` — the host file
    server URL the listener bound to, plus the consumer-supplied artifact
    version. Forwarded the same way as the token; the pair arrives
    together or not at all, and requires a declared extra vault to have a
    consumer; partial or orphaned sets are rejected before any helper runs.
  - `--consumer-root <path>` (optional) — when a consumer owns the
    per-domain fragment, resolve `_build-extra-vars-<Name>.sh` from
    `<path>/ops` instead of this composer's own directory. The inventory
    fragment is always substrate and is unaffected. Empty keeps every
    fragment on the composer's own `ops/` (the substrate's own flows).
  The always-on inventory helper owns its own validation and bats
  coverage:
  - [`ops/virtual-machines/_build-extra-vars-inventory.sh`](ops/virtual-machines/_build-extra-vars-inventory.sh)
    — emits `vm_provisioner_config`. Always-on; the inventory source
    every payload domain shares.
  Every other payload fragment is consumer-owned: dispatch resolves
  `_build-extra-vars-<Name>.sh` from `<consumer-root>/ops`, so the
  substrate ships none of them.
  Config inputs are file paths (not values) so secrets stay out of
  argv. The GitHub token is the lone exception, passed by value
  because the entry script already holds it in a shell variable;
  argv on Linux is private to the owning user's process tree.
  Keeping dispatch a pure `<Name>` derivation here (the layer that
  already dispatches per domain) is what lets the orchestrator stay
  ignorant of any specific consumer. Future payload domains (e.g.
  toolchain delivery: JDK / .NET SDK / file copy) land as a peer
  `_build-extra-vars-<Name>.sh` dispatched by the same derivation —
  the bridge already forwards every declared vault verbatim, so no
  call site here changes.
- [`ops/_run-playbook.sh`](ops/_run-playbook.sh) - thin,
  consumer-agnostic orchestrator. Validates args, parses the consumer
  contract (via `_parse-consumer-contract.sh`), sets up a
  per-invocation `mktemp -d` tree (`chmod 700`, files `chmod 600`,
  cleaned up by `EXIT` trap), activates `.venv`, drives the helpers in
  order, and dispatches `ansible-playbook` against the requested
  playbook path. Reads the contract-declared inventory vault
  (`CA_INVENTORY_VAULT`) unconditionally - the fleet every dispatch
  targets - deriving its secret as `<Name>Config-<suffix>`, and then
  reads each vault the contract's `CA_EXTRA_VAULTS` declared,
  generically, into its own tmpdir file - so a consumer pays only for
  what it declares, and the bridge names no vault at all (inventory
  provider or consumer alike).
  Each declared extra vault is forwarded to the composer as a generic
  `--vault-config <Name>=<path>` pair. The contract's
  `CA_NEEDS_HOST_FILE_SERVER=1` controls the Windows-side staging:
  when set, the bridge delegates to `_stage-host-fileserver.sh` and
  (via the EXIT trap) stops the listener it backgrounded on every exit
  path; when unset, neither the listener nor the stop call run, and the
  file-server-pair extra-vars keys are genuinely absent. The host file
  server and the GitHub token are independent opt-ins: a flow can serve
  artifacts consumers pull by name (e.g. toolchain tarballs) with
  `CA_NEEDS_HOST_FILE_SERVER=1` and no token, and another can require a
  token with no file server. `GH_TOKEN` is
  lifted to a local when the contract
  requires a token and then cleared from the bridge environment
  unconditionally before `ansible-playbook` runs; the downstream play
  receives the token via the chmod-600 extra-vars file only. Any args
  after the playbook path are forwarded verbatim to `ansible-playbook`
  (so `--tags`, `--limit`, `--check`, `-v`, etc. all work without
  changes to the bridge). When the contract names `CA_CONSUMER_ROOT`,
  the playbook resolves under that root, `_ansible-env.sh` puts the
  consumer's `<root>/roles` ahead of the substrate `roles/` on
  `ANSIBLE_ROLES_PATH`, and the composer is handed `--consumer-root` so
  the per-domain fragment resolves from there too - so a consumer owns
  its playbook, roles, and fragment while reusing this bridge. Empty
  keeps all three on the substrate's own root (the path the bridge's own
  flows take). Under a Git Bash launch the root is translated to the
  `/mnt/...` form and forwarded over `WSLENV` with the other `CA_*`
  variables before the WSL re-exec.
- [`ops/virtual-machines/_stage-host-fileserver.sh`](ops/virtual-machines/_stage-host-fileserver.sh)
  - host file server opt-in branch. Serve-only: the consumer supplies the
  already-staged directory and its artifact version, so this helper just
  picks the bind IP from the provisioner config, starts the listener over
  that directory (one pwsh.exe round-trip), polls the backgrounded
  listener for `BASE_URL=` + `PID=`, and emits its own three-line contract
  on stdout (`RUNNER_VERSION=`, `BASE_URL=`, `PID=`) for the bridge to
  parse.
- [`ops/virtual-machines/_start-host-file-server.ps1`](ops/virtual-machines/_start-host-file-server.ps1)
  - long-lived listener. Binds an `HttpListener` to the host adapter
  whose IP shares a /24 with the target VM (same algorithm as
  `Start-VmFileServer` in Infrastructure.HyperV), serves any file in
  the supplied `-StagingDir` by its basename, prints `BASE_URL=<url>`
  then `PID=<pid>` on stdout, and blocks until killed. Multi-file
  serving leaves room for a future toolchain-delivery feature to
  stage extra payloads in the same dir.
- [`ops/virtual-machines/_stop-host-file-server.ps1`](ops/virtual-machines/_stop-host-file-server.ps1)
  - idempotent stop helper. Force-stops the listener process by PID
  and waits for exit; a missing PID is treated as already-stopped.
- [`ops/virtual-machines/_resolve-router.sh`](ops/virtual-machines/_resolve-router.sh)
  - router/NAT resolution, sourced by the bridge. `resolve_router`
  finds the `kind: router` row, resolves its upstream IP (static from
  the vault or Hyper-V KVP), applies the WSL host-portproxy redirect to
  the SSH endpoint, exports `ROUTER_*` / `SSHPASS` for the inventory
  builder and host-file-server staging, and runs the reachability
  pre-flight via
  [`ops/virtual-machines/_assert-router-reachable.sh`](ops/virtual-machines/_assert-router-reachable.sh).
  Sourced (not exec'd) because it must set those env vars in the
  bridge's own shell and never route the router password through a
  child's stdout. A no-op on single-switch fleets.

External contract (consumed by feature playbooks): the extra-vars
document always has the top-level key `vm_provisioner_config` (the
shared inventory). Most other keys are contributed by whichever
per-domain helper a declared vault dispatched to, and are present only
when the contract declared that vault (`CA_EXTRA_VAULTS`). One
cross-cutting key is the exception: with `CA_NEEDS_HOST_FILE_SERVER=1`
the bridge emits `host_file_server_base_url` from the always-on
inventory fragment, so the URL reaches the roles whether or not any
extra vault is declared (the file server is a property of the run, not
of a vault). The GitHub token (with `CA_REQUIRES_TOKEN=1`) still reaches
only the declared vault helper that consumes it and surfaces as that
helper's key. The inventory has one group `vm_provisioner_hosts` keyed
by `vmName`.

### The toolchains taxonomy block (vm_provisioner_config.toolchains)

Each VM definition in the provisioner config carries an optional
`toolchains` block declaring which tools land on that box, classified by
**how each is acquired** (the three-section acquisition taxonomy):

```json
{
  "vmName": "ubuntu-02-ci",
  "toolchains": {
    "hostPushed":   [ { "name": "jdk",        "version": "21.0.2+13" } ],
    "vmDownloaded": [ { "name": "shellcheck", "version": "0.9.0-1"  } ],
    "baseImage":    [ { "name": "docker" } ]
  }
}
```

- `hostPushed` - section 1: heavy artifacts the host caches once and
  pushes over the file server (JDK, .NET SDK), consumed by the
  [host-push roles](#host-push-toolchain-pattern-toolchain_host_push).
- `vmDownloaded` - section 2: small packages the VM fetches itself,
  consumed by [`toolchain_apt`](#section-2-apt-toolchain-pattern-toolchain_apt).
- `baseImage` - section 3: daemons installed at a coarser grain,
  consumed by the [`docker`](#section-3-docker-daemon-docker) role.

The block lives in the existing per-VM secret (one per-VM SSOT); the
config is surfaced whole under `vm_provisioner_config`, so the block rides
along untouched and a consumer playbook dispatches each section into its
roles' vars (the substrate ships no such playbook - that mapping is the
consumer's, keeping the naming honest).

Validation is split by ownership. The substrate validates only the
**outer taxonomy shape** - at the surfacing point, in
[`ops/virtual-machines/_validate-toolchains-config.sh`](ops/virtual-machines/_validate-toolchains-config.sh):
the block must be an object, name none but the three known sections, and
give each present section as a list; a violation fails the run with a
message naming the VM and the offending section. Each toolchain **role**
validates its own section's **entries** (e.g. `toolchain_apt` asserts
every entry names a package). The section boundary is only visible before
dispatch, so an unknown-section message can only come from the taxonomy
layer - which is why the shape check lives here rather than in a role. The
block is optional and absent-safe: a VM with no `toolchains` key validates
and provisions exactly as before. The PowerShell config validator ignores
the block (it validates required fields and tolerates extra keys), so the
Ansible taxonomy and the reconciler schema coexist in one secret.

`jq` is a hard runtime dependency (JSON validation, inventory and
extra-vars composition); [`ops/_bootstrap-controller-wsl.sh`](ops/_bootstrap-controller-wsl.sh)
installs it via `sudo apt-get` when absent and falls back to the
`sudo apt-get install -y jq` hint if the install itself cannot
proceed.

Each bash helper has its own bats suite under
[`Tests/ops/`](Tests/ops/) covering its boundary in isolation;
`_run-playbook.bats` stubs `pwsh.exe`, `ansible-playbook`, and the
sibling bash helpers, then asserts orchestration only. The two
host-file-server PowerShell helpers are covered by
[`Tests/ops/Start-HostFileServer.Tests.ps1`](Tests/ops/Start-HostFileServer.Tests.ps1)
- Pester rather than bats because each helper is single-file
PowerShell calling `HttpListener` or `Get-NetIPAddress`; mocking
those from bats would require a `pwsh.exe` round-trip per assertion.
The end-to-end smoke against a real VM is captured in the feature plan.

## Reusable roles

The substrate ships reusable roles under [`roles/`](roles/), consumed by
their short name once `<root>/roles` is on `ANSIBLE_ROLES_PATH` (see
[Consuming the substrate](#consuming-the-substrate)). Roles read the
extra-vars and inventory the bridge composes and are not standalone.

### Host-push toolchain pattern (toolchain_host_push)

[`roles/toolchain_host_push`](roles/toolchain_host_push/) is the shared
**section-1** ("host-prefetched, pushed") toolchain mechanism: it pulls a
host-staged tarball via the substrate host file server, extracts it to a
versioned install dir (`/opt/<tool>-<version>`), wires `/usr/local/bin`
symlinks and an `/etc/profile.d/<tool>.sh` script, records each install as
a manifest, and removes versions no longer desired (the one capability
Ansible does not give for free - a set-difference uninstall). It ports the
PowerShell toolchain reconciler's model
(`Infrastructure-Vm-Provisioner` `up/reconciler`) so the later `jdk` /
`dotnet_sdk` roles differ only in their resolve/version logic and delegate
the mechanics here.

The record model is deliberately **manifest-per-version**, not an
`/opt/<tool>-*` directory glob: the manifest records the exact install
dir, symlinks, and profile script the install created, so uninstall undoes
precisely that instead of racing a glob against whatever an operator added
by hand. Install writes the manifest last and uninstall removes it last,
so a crash mid-operation is self-healing. Full var contract, flow, and the
molecule scenarios are documented in the
[role README](roles/toolchain_host_push/README.md).

The pattern supports two symlink modes per version: an explicit `symlinks`
list, and `symlink_bin_dir` - a subdir whose files are all symlinked into
`/usr/local/bin`, enumerated at install time (for tools like the JDK whose
launcher set is only known post-extraction). Both record every link in the
manifest, so uninstall stays glob-free. A per-version `owned_files` list is
the generic escape hatch for a tool that needs a fixed config file *outside*
its install dir (e.g. .NET's `/etc/dotnet/install_location`): the pattern
writes it at install and removes it on uninstall, recording the path in the
manifest so removal stays glob-free too.

### JDK (jdk)

[`roles/jdk`](roles/jdk/) is the first real consumer of the host-push
pattern. It adds **only** Adoptium (Eclipse Temurin) version-pin
resolution: an operator pin (`21`, `21.0`, `21.0.5`, or `21.0.5+11`)
resolves against the Adoptium v3 API into a concrete
`{version, tarball name}`, and the install / version-swap / uninstall
mechanics delegate to `toolchain_host_push` (`symlink_bin_dir: bin` links
every JDK launcher, and a `JAVA_HOME` + `PATH` profile is written). v1
installs one JDK per host. It ports the PowerShell reconciler's
`JdkProvider`; full contract, the resolution table, and the molecule
scenarios are in the [role README](roles/jdk/README.md).

### .NET SDK (dotnet_sdk)

[`roles/dotnet_sdk`](roles/dotnet_sdk/) is the second real consumer of the
host-push pattern. It adds **only** .NET release-feed resolution: an
operator `{channel, version}` pin (channel `10.0`; version `10`, `10.0`, or
`10.0.100`) resolves against Microsoft's per-channel `releases.json` into a
concrete `{version, tarball name}`, and the install / version-swap /
uninstall mechanics delegate to `toolchain_host_push`. The .NET specifics
it composes onto the pattern are a flat extract (`strip_components: 0`), a
single `dotnet` driver symlink, a `DOTNET_ROOT` + tools-PATH +
telemetry-opt-out profile, and an `owned_files` entry for
`/etc/dotnet/install_location` (the non-login-shell runtime hint). v1
installs one SDK per host. It ports the PowerShell reconciler's
`DotnetSdkProvider`; full contract, the resolution table, and the molecule
scenarios are in the [role README](roles/dotnet_sdk/README.md).

### .NET global tools (dotnet_tools)

[`roles/dotnet_tools`](roles/dotnet_tools/) is the nested global-tools half
of the .NET toolchain (the SDK half is `dotnet_sdk`). Unlike the tarball
roles it does **not** build on `toolchain_host_push`: a global tool is a
NuGet package installed by the `dotnet tool` driver, so the role installs
each desired `{id, version}` via an offline `dotnet tool install` from a
pinned local source, symlinks the command shim into `/usr/local/bin`, and
records a manifest for glob-free removal - mirroring the tarball roles'
manifest-driven reconcile rather than delegating to it. Because every
`dotnet tool` operation needs the SDK's `dotnet` driver, a consumer play
installs it **after** the SDK and, on teardown, removes it **before** the
SDK (tools removed first) - the Ansible expression of the parent/child
teardown ordering the PowerShell children-walker guaranteed. It ports the
reconciler's `DotnetToolsProvider`; full contract, the ordering rationale,
and the molecule scenarios are in the
[role README](roles/dotnet_tools/README.md).

### Section-2 apt toolchain pattern (toolchain_apt)

[`roles/toolchain_apt`](roles/toolchain_apt/) is the shared **section-2**
("VM-downloaded") toolchain mechanism - the counterpart to the section-1
host-push pattern. Small distro packages (shellcheck, bats) are not worth
host-staging and pushing over the file server: apt on the target fetches
them itself over its normal egress, and apt is already the installed-state
source of truth, giving idempotent install and removal for free. So the
role is deliberately thin - no host staging, no file server, no manifest.
It installs a set of `{name, version}` entries in one apt transaction at
`state: present` with `allow_downgrade`, so an exact pin is authoritative
and re-provision-safe. The one task that could report a spurious change,
the apt cache refresh, is throttled by `toolchain_apt_cache_valid_time` so
a re-run is a genuine no-op.

Its shipped use is shellcheck pinned to `0.9.0-1` (the apt candidate on the
target's Ubuntu 24.04), which unblocks the `ci-bash` shellcheck step on the
runner VM without a runtime install. Full var contract and the molecule
scenario are in the [role README](roles/toolchain_apt/README.md).

### Section-3 Docker daemon (docker)

[`roles/docker`](roles/docker/) is the **section-3** ("base-image /
daemon") toolchain mechanism - the counterpart to the section-1 host-push
and section-2 apt patterns. A daemon is a rarely-versioned service, so it
is installed at a coarser grain: Docker's own apt repo (GPG key in a
dedicated keyring, `signed-by`-scoped so it authorises only Docker's
source), the Docker CE engine package set, the `docker` systemd service
enabled and started, and the runner service user added to the `docker`
group so it reaches the socket without sudo. Group membership is the one
var a consumer normally sets (`docker_group_members`); it is additive and,
because the group is root-equivalent, deliberately opt-in rather than
granted automatically. Provisioned by an Ansible role rather than
base-image baking because this estate has no golden-image pipeline (see the
role README for the rationale).

The molecule scenario is genuine docker-in-docker - a privileged,
systemd-init container so the inner daemon really starts and `verify` can
run `docker ps`. Full var contract, the security note, and the
docker-in-docker caveat are in the [role README](roles/docker/README.md).

## Tests and lint

CI is wired to three reusable workflows; nothing is copied per-repo:

- [`.github/workflows/ci-powershell.yml`](.github/workflows/ci-powershell.yml)
  -> `Common-PowerShell/.github/workflows/ci-powershell.yml@master`
  (Pester unit tests + `lint-no-bare-return-empty-array`).
- [`.github/workflows/ci-bash.yml`](.github/workflows/ci-bash.yml)
  -> `Common-Automation/.github/workflows/ci-bash.yml@master` (shellcheck
  on production bash + `*.bats` suites + `+x` bit check).
- [`.github/workflows/ci-yaml.yml`](.github/workflows/ci-yaml.yml)
  -> `Common-Automation/.github/workflows/ci-yaml.yml@master` (yamllint,
  actionlint, action-validator, ansible-lint).

This repo carries **no E2E gate of its own**. As the consumed substrate
(dispatch bridge + reusable roles), its real-VM behaviour is exercised
end-to-end by the consumers' E2E gates - each consumer checks
Common-Ansible out as a sibling and runs its own flow through this
bridge - so a per-PR live-Hyper-V run here would only duplicate that
coverage (and, for the user layer, gate this repo's PRs on a domain it
no longer owns). The substrate's own bar is the bats suites plus the
lint workflows above.

The same checks run locally via thin shims that delegate to the
canonical runners in the sibling repos (so a fix to the CI logic
lands in one place):

- [`scripts/Run-Tests.ps1`](scripts/Run-Tests.ps1) -> calls
  `Common-PowerShell/.github/actions/run-unit-tests/Run-Tests.ps1`.
- [`scripts/run-ci-yaml-and-bash.sh`](scripts/run-ci-yaml-and-bash.sh)
  (with its [`.bat`](scripts/run-ci-yaml-and-bash.bat) Explorer launcher)
  is the MAIN entry -> delegates to Common-Automation's orchestrator to run
  BOTH the lint suite AND the bats tests in one go, the full local
  equivalent of `ci-yaml.yml` + `ci-bash.yml`.
- [`scripts/run-lint-yaml-and-bash.sh`](scripts/run-lint-yaml-and-bash.sh)
  (with its [`.bat`](scripts/run-lint-yaml-and-bash.bat) launcher) ->
  delegates to Common-Automation to run the lint half only (shellcheck,
  actionlint, action-validator, yamllint, ansible-lint); no bats.
- [`scripts/run-tests-bash.sh`](scripts/run-tests-bash.sh)
  (with its [`.bat`](scripts/run-tests-bash.bat) launcher) -> delegates to
  Common-Automation to run the bats tests only.
- [`scripts/fix-permissions.sh`](scripts/fix-permissions.sh) /
  [`scripts/fix-permissions.bat`](scripts/fix-permissions.bat) ->
  forward to `Common-Automation/scripts/fix-permissions.{sh,bat}` to
  re-stage `+x` on tracked `*.sh` files that lost it (heals what the
  `check-sh-executable` CI gate flags).

These shims assume `Common-PowerShell` and `Common-Automation` are sibling
checkouts under the same parent directory. The same assumption now extends
to the operator-side `ops/` bridge: `_run-playbook.sh` and
`_stage-host-fileserver.sh` source the generic `_to_windows_path` helper
from `Common-Automation/scripts/_to-windows-path.sh` (single source of
truth for the WSL->Windows path conversion that keeps `pwsh.exe -File`
from exiting 64). They resolve it from the sibling checkout by default;
`COMMON_AUTOMATION_ROOT` overrides the root, which the bats suites use to
point the source at a mocked copy.

## Consuming the substrate

The reusable roles in [`roles/`](roles/) are **not standalone** - they
read the extra-vars and inventory the dispatch bridge composes (the
always-on `vm_provisioner_config` inventory plus whatever per-domain keys
a consumer's `_build-extra-vars-<Name>.sh` fragment contributes). Roles
and bridge are therefore one cohesive substrate and are consumed
**together, through a single sibling checkout** - not split across two
transports.

A consumer keeps Common-Ansible checked out alongside it (under the same
parent, e.g. `c:\a_Code\Common-Ansible`) and resolves that root once -
the same adapter pattern
[`ops/imports/_common-automation-root.sh`](ops/imports/_common-automation-root.sh)
already uses for Common-Automation, overridable with
`COMMON_ANSIBLE_ROOT`. From that one root it gets both:

- **roles** - by adding `<root>/roles` to `ANSIBLE_ROLES_PATH`, so
  playbooks reference substrate roles by their short name; and
- **the ops bridge** - by sourcing/exec'ing `<root>/ops/` (the
  controller bootstrap and `_run-playbook.sh` dispatch).

The two bullets above cover a consumer reusing the **substrate's own**
roles by short name. A consumer that owns roles and a playbook of its
own - the user and runner owners, whose domain roles live in their
repo, not here - declares its repo root through `CA_CONSUMER_ROOT`
(part of the bridge contract). The bridge then resolves that consumer's
playbook, puts its `<consumer-root>/roles` ahead of the substrate
`roles/` on `ANSIBLE_ROLES_PATH`, and resolves its per-domain
extra-vars fragment from `<consumer-root>/ops` - so the consumer owns
its playbook, roles, and fragment while the substrate carries none of
that domain. The substrate's own wrappers leave `CA_CONSUMER_ROOT`
unset and resolve everything from this root unchanged.

Infrastructure-Vm-Users is the reference consumer. A published Galaxy
collection was considered and rejected: a collection can carry only the
roles (the ops bridge cannot ship in one - the controller bootstrap that
builds the venv that runs `ansible-galaxy` is itself part of the bridge),
and the roles have no value without the bridge, so a collection would
split one indivisible substrate into two transports for no gain. If a
genuinely standalone role library emerges later (e.g. the section-2/3
toolchain roles, which need no bridge contract), that subset is a fair
candidate to publish on its own.

## Feature folders

- [Current feature: 08 - GitHub runners registration](docs/dev/implementation/08-github-runners-registration/)
  - [Problem](docs/dev/implementation/08-github-runners-registration/problem.md)
  - [Plan](docs/dev/implementation/08-github-runners-registration/plan.md)
- [03 - groups, users, sudoers removal](docs/dev/implementation/03-groups-users-sudoers-removal/)
  - [Problem](docs/dev/implementation/03-groups-users-sudoers-removal/problem.md)
  - [Plan](docs/dev/implementation/03-groups-users-sudoers-removal/plan.md)
- [02 - groups, users, sudoers creation](docs/dev/implementation/02-groups-users-sudoers-creation/)
  - [Problem](docs/dev/implementation/02-groups-users-sudoers-creation/problem.md)
  - [Plan](docs/dev/implementation/02-groups-users-sudoers-creation/plan.md)
