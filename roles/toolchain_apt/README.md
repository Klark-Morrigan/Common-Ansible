# Role: toolchain_apt

Installs a set of pinned apt packages directly on the target VM,
idempotently. It is the shared **section-2** ("VM-downloaded") toolchain
mechanism - the counterpart to the section-1
[host-push pattern](../toolchain_host_push/README.md). Where host-push
caches heavy tarballs on the host and pushes them over the substrate file
server, section-2 leans on the target's own apt archive for tools small
enough to pull straight from the distro. It ships with two pinned uses -
shellcheck for the `ci-bash` lint step and bats for the `ci-bash` test
step; see
[the plan](../../docs/dev/implementation/19-common-ansible-extraction-and-toolchain-provisioning/plan.md#step-61---toolchain_apt-role-with-a-shellcheck-pinned-use).

## Index

- [Var contract](#var-contract)
- [What it does](#what-it-does)
- [Why apt, not host-push](#why-apt-not-host-push)
- [Idempotence](#idempotence)
- [The pinned uses it ships with](#the-pinned-uses-it-ships-with)
- [Consuming this role](#consuming-this-role)
- [Tests](#tests)

## Var contract

Full field documentation lives in
[`defaults/main.yml`](defaults/main.yml). In brief:

- `toolchain_apt_packages` (default `[]`) - the desired apt packages.
  Empty is a no-op (the role only refreshes the apt cache), so a play can
  always include it and let config decide the set. Each entry:
  - `name` (required) - apt package name (e.g. `shellcheck`).
  - `version` (optional) - the exact apt version to pin (e.g.
    `0.9.0-1`). Pinned installs are authoritative and downgrade a
    drifted-ahead build; omitted means "apt's candidate", not pinned.
- `toolchain_apt_cache_valid_time` (default `3600`) - seconds the role
  trusts a previously-refreshed apt cache before updating it again. This
  throttle is what makes a re-run a genuine no-op (see
  [Idempotence](#idempotence)).

## What it does

1. Asserts every entry names a package (a config typo fails here, naming
   the offending entry, rather than as an opaque apt error later).
2. Composes the apt name specifiers - `name` when unpinned,
   `name=version` when pinned.
3. Refreshes the apt cache, throttled by `toolchain_apt_cache_valid_time`.
4. Installs the whole set in one apt transaction at `state: present` with
   `allow_downgrade` so an exact pin always wins.

```mermaid
flowchart LR
  PKGS[toolchain_apt_packages] --> SPEC[compose name / name=version]
  SPEC --> CACHE[apt cache refresh - throttled]
  CACHE --> INST[apt install pinned set]
  INST --> BIN[/tool on PATH at the pinned version/]
```

## Why apt, not host-push

The section-1 host-push pattern exists because heavy toolchains (a JDK, a
.NET SDK) are large, versioned artifacts worth caching once on the host
and pushing to each VM over the measured NAT-bypass file server, with a
manifest-driven uninstall Ansible does not give for free. Section-2 tools
(shellcheck, bats) are small distro packages: apt fetches them itself over
the VM's normal egress, and apt is *already* the installed-state source of
truth, so it provides idempotent install and its own removal for free.
Reusing the host-push machinery for them would add a host staging step, a
file server round-trip, and a bespoke manifest for no benefit. That is why
this role is deliberately thin - it has no staging, no file server, and no
manifest of its own.

## Idempotence

apt makes an already-installed exact-version package a no-op, so the
install task alone re-runs clean. The one thing that could report a
spurious change is the cache refresh, so it is split into its own task
throttled by `toolchain_apt_cache_valid_time`: the first run on a fresh VM
(empty cache) refreshes, and any re-run inside the window does not - so the
whole role reports `changed: 0` on the second pass. The molecule scenario
asserts this via `molecule idempotence`.

## The pinned uses it ships with

The role ships with two pinned uses, both apt candidates on the target's
Ubuntu 24.04 (noble/universe). Each carries a known version onto the runner
VM rather than depending on a runtime install, so the `ci-bash` lint and
test steps are self-sufficient and re-provision-safe. Both pins are
exercised end to end by their own molecule scenario (install, on PATH,
exact version, idempotent re-run).

- **shellcheck** pinned to `0.9.0-1` - the `ci-bash` lint step. Unblocks
  the original shellcheck failure this role was created for.
- **bats** pinned to `1.10.0-1` - the `ci-bash` test step. Its molecule
  scenario additionally runs a trivial `.bats` file, since a test runner
  being on PATH is not the same as it being able to execute a test.

```yaml
- name: Install the pinned CI toolchain packages
  ansible.builtin.include_role:
    name: toolchain_apt
  vars:
    toolchain_apt_packages:
      - name: shellcheck
        version: "0.9.0-1"
      - name: bats
        version: "1.10.0-1"
```

## Consuming this role

Include it with the desired package set (see the example above). A tool
too new or absent from the distro archive is out of scope for this role -
it is the apt mechanism of the section-2 taxonomy; a `get_url`
static-binary sibling covers tools apt cannot serve, added when a consumer
first needs one.

## Tests

[`Tests/molecule/toolchain_apt/`](../../Tests/molecule/toolchain_apt/) has
one scenario per shipped use, each covering the plan's cases against a real
container pulling the package from the Ubuntu archive:

- **default** (shellcheck):
  - **prepare** asserts shellcheck is absent - the "absent" baseline.
  - **converge** installs `shellcheck=0.9.0-1` via the role; `molecule
    idempotence` re-runs it and asserts `changed: 0`.
  - **verify** asserts shellcheck is on PATH, runs and reports `0.9.0`, and
    that apt records the exact pinned `0.9.0-1` (so a drifted build fails
    the pin even if the upstream version string still matched).
- **bats**: the same absent -> present -> on PATH -> exact pin ->
  idempotent shape for `bats=1.10.0-1`, and additionally drops a trivial
  `.bats` file and runs it green - proving the installed runner can execute
  a test, not merely that the binary resolves on PATH.

Both scenarios reuse the `toolchain_host_push` base image (python3 + sudo
on ubuntu:24.04) - apt is the whole mechanism, so no localhost fixture is
needed.
