# Problem: Consolidate ansible-lint CI into Common-Ansible

## Index

- [Summary](#summary)
- [For laymen](#for-laymen)
- [Background](#background)
- [What is changing](#what-is-changing)
- [Why this belongs in Common-Ansible](#why-this-belongs-in-common-ansible)
- [Solution approach](#solution-approach)
  - [Off-the-shelf survey - the linter](#off-the-shelf-survey---the-linter)
  - [Off-the-shelf survey - the placement](#off-the-shelf-survey---the-placement)
  - [Decision: execution model - controller venv](#decision-execution-model---controller-venv)
    - [The hermeticity trade-off and how it is closed](#the-hermeticity-trade-off-and-how-it-is-closed)
    - [Runner-environment gating and the controller provider](#runner-environment-gating-and-the-controller-provider)
  - [Decision: scope - full migration](#decision-scope---full-migration)
  - [Chosen direction](#chosen-direction)
- [Relationship to feature 21](#relationship-to-feature-21)
- [Constraints](#constraints)
- [Risks and sequencing](#risks-and-sequencing)
- [Out of scope](#out-of-scope)

## Summary

`ansible-lint` runs today as a composite action in **Common-Automation**
(`.github/actions/ansible-lint`), invoked as the last step of the
reusable `ci-yaml.yml` workflow that every repo delegates to. But
ansible-lint targets a single-ecosystem surface - `playbooks/`,
`roles/`, `ansible.cfg` - that only the Ansible repos have. Common-
Automation's stated charter is the opposite: "Shared, tech-agnostic
GitHub Actions composite actions and reusable workflows ... outside any
single language ecosystem ... without dragging tooling along." An
Ansible-specific gate baked into the universal YAML workflow is a domain
leak: every PowerShell, .NET, and bash repo carries an Ansible step it
can never use, and the Ansible domain's CI lives apart from the Ansible
controller repo that owns the Ansible toolchain.

This feature moves the ansible-lint gate out of Common-Automation's
`ci-yaml.yml` into a reusable workflow owned by **Common-Ansible** (the
Ansible controller repo), consumed only by repos that actually contain
Ansible content. Common-Automation keeps only the cross-cutting linters
that nearly every repo has.

## For laymen

Think of Common-Automation as a shared toolbox every team borrows from -
but it is meant to hold only tools everyone uses (spell-checkers for
config files, that sort of thing). One Ansible-only tool got left in
that shared toolbox, so every team sees it even though only the Ansible
teams can use it. It quietly does nothing for the others, but it does not
belong there. This change moves that Ansible-only tool into the Ansible
team's own toolbox, where it lives next to the rest of the Ansible
machinery. Nothing about how Ansible code is checked changes - only where
the check is defined and who picks it up.

## Background

- Common-Automation hosts the org's reusable CI: the composite actions
  (`shellcheck-bash`, `yamllint`, `actionlint`, `action-validator`,
  `ansible-lint`, `test-bats`, ...) and the two reusable workflows
  `ci-yaml.yml` and `ci-bash.yml`. Its README opens by declaring it
  tech-agnostic and consumable by PowerShell, .NET, and future stacks
  without dragging tooling along.
- `ci-yaml.yml` runs four linters as sequential steps of one job:
  `yamllint`, `actionlint`, `action-validator`, then `ansible-lint`.
  Every consumer repo's thin `ci-yaml.yml` delegates to it with
  `uses: Klark-Morrigan/Common-Automation/.github/workflows/ci-yaml.yml@master`.
- The ansible-lint composite auto-skips when a repo has no `playbooks/`,
  `roles/`, or `ansible.cfg`, so at a non-Ansible repo it is a no-op
  skipped step, not wasted linting. It runs in its own pinned Docker
  image, so it drags no Ansible toolchain into Common-Automation's
  runtime.
- The remaining `ci-yaml` linters target surfaces nearly every repo has:
  `yamllint` (any YAML), `actionlint` / `action-validator` (GitHub
  Actions YAML). Those are genuinely cross-cutting; ansible-lint is the
  only step whose surface is single-ecosystem.
- Common-Ansible is "the Ansible controller repo": it already owns the
  Linux venv, `ansible-core`, the pinned Galaxy collections
  (`requirements.yml`), and the controller bootstrap. It is the home of
  the Ansible domain.

## What is changing

1. A new reusable workflow in Common-Ansible, `ci-ansible.yml`, carries
   the ansible-lint gate. This feature creates that workflow with
   ansible-lint as its first gate; [feature 21](../21-molecule-ci-in-common-ansible/problem.md)
   then adds `molecule` to the same `ci-ansible.yml` as a second,
   path-gated job. One Ansible-domain workflow, ansible-lint first,
   molecule second (see [Relationship to feature 21](#relationship-to-feature-21)).
   The gate runs ansible-lint from Common-Ansible's controller venv (not
   a Docker composite - see [Decision: execution model](#decision-execution-model---controller-venv)),
   which is the same toolchain feature 21's molecule job already needs.
2. `ansible-lint` is pinned in Common-Ansible's `requirements.txt`
   alongside `ansible-core`, and the strict `production` default config
   (`ansible-lint.config.yml`) plus the auto-skip / consumer-config
   resolution helper move into Common-Ansible. The Docker execution path
   is dropped entirely: no `Dockerfile`, no `retry.sh` dependency (there
   is no image build to retry), no `versions.env` `ANSIBLE_LINT_VERSION`
   entry, and no `get-ansible-lint-version.sh` - the version pin now lives
   in `requirements.txt`, where Common-Ansible already single-sources its
   Ansible toolchain versions.
3. The ansible-lint step (both the self and consumer branches) is removed
   from Common-Automation's `ci-yaml.yml`, and the `ansible-lint`
   composite action tree plus its now-orphaned lib dependencies are
   deleted from Common-Automation. It is left with only the cross-cutting
   linters (`yamllint`, `actionlint`, `action-validator`).
4. Every Ansible consumer repo is rewired: its thin workflow stops getting
   ansible-lint from `ci-yaml.yml` and starts consuming Common-Ansible's
   Ansible-domain workflow. Three consumers carry existing coverage across
   unchanged (Common-Ansible itself, Infrastructure-Vm-Users,
   Infrastructure-GitHubRunners - all with a root `ansible.cfg` today). A
   fourth, Infrastructure-Vm-Provisioner, has a nested Ansible slice whose
   substrate-composing playbook auto-skipped the old gate (no root
   `ansible.cfg`); it is brought under the new gate for the first time,
   which the new workflow can do because it stages the substrate roles the
   composer references (`jdk`, `dotnet_sdk`, `dotnet_tools`) - a small
   coverage addition alongside the relocation, not a rule change.
5. The local pre-push runners are updated on both sides: Common-Automation's
   `_run-lint-yaml-and-bash.sh` drops its `run_ansible_lint` step, and
   Common-Ansible gains a venv-based local ansible-lint step so its own
   pre-push run still covers its roles (matching the `lint-ansible` skill,
   which already runs `.venv/bin/ansible-lint`).
6. Non-Ansible repos simply stop carrying the (skipped) Ansible step.

## Why this belongs in Common-Ansible

The estate's two repo prefixes carry distinct meanings (see feature 19's
[Why Common-, not Infrastructure-](../19-common-ansible-extraction-and-toolchain-provisioning/problem.md#why-common--not-infrastructure)):
`Common-*` is reusable substrate, and within that, each Common- repo owns
one domain - Common-Automation owns tech-agnostic CI, Common-PowerShell
owns shared cmdlets, Common-Ansible owns the Ansible substrate.

ansible-lint is Ansible-domain tooling. Its correct owner is the repo
that owns the Ansible domain, which is Common-Ansible. It currently sits
in Common-Automation only because a dockerised, auto-skipping composite
is cheap to leave in the universal workflow - an ergonomic accident, not
a domain decision. The cross-cutting linters (`yamllint`, `actionlint`,
`action-validator`, `shellcheck`) stay in Common-Automation because their
surfaces are not tied to any one ecosystem; ansible-lint is the lone
exception, and this feature corrects it.

## Solution approach

### Off-the-shelf survey - the linter

The tool itself is not in question; the survey is recorded for
completeness.

| Option | Source / license | Fit | Notes |
| --- | --- | --- | --- |
| **ansible-lint** | OSS, GPL-3.0, Ansible community | The de-facto linter for playbooks/roles/ansible.cfg; production-profile gate already in use here | Keep - already adopted, no reason to switch |
| `yamllint` alone | OSS, GPL-3.0 | Catches YAML style only, none of the Ansible semantics (module misuse, deprecations, role-name rules) | Insufficient on its own; already retained for generic YAML |
| Custom rules | In-repo | Reinvents a mature ruleset | Rejected |

Decision: keep ansible-lint as the tool. The feature is about its
**placement**, not its replacement.

### Off-the-shelf survey - the placement

| Option | Fit | Cost | Notes |
| --- | --- | --- | --- |
| Status quo (Common-Automation `ci-yaml`) | Works mechanically via auto-skip | Domain leak: Ansible gate in every repo's universal workflow; violates the tech-agnostic charter | Rejected |
| **Reusable workflow in Common-Ansible** | Domain-correct: Ansible CI owned by the Ansible repo; non-Ansible repos drop the step | One extra reusable workflow + one extra PR-check row for Ansible repos; an extra cross-repo `uses:` | Chosen |
| Inline ansible-lint per Ansible repo | Removes the shared dependency | Re-duplicates the ruleset/pins across three repos; drift | Rejected - violates single-source-of-truth |

### Decision: execution model - controller venv

The dockerised composite in Common-Automation packaged its own
ansible-lint image (a `Dockerfile` pip-installing a pinned version) so a
tech-agnostic repo would not have to host the Ansible toolchain, and
wrapped the image build in the `retry.sh` primitive against transient
registry blips. In Common-Ansible that indirection is gone: the repo is
the Ansible controller and already owns a venv with `ansible-core` and the
pinned Galaxy collections, and feature 21's molecule job will drive that
same venv. Running ansible-lint natively from `.venv/bin/ansible-lint`
therefore reuses the toolchain the repo exists to own, rather than
spinning up a second, containerised copy of it.

| Option | Fit | Cost | Notes |
| --- | --- | --- | --- |
| **Controller venv** (`.venv/bin/ansible-lint`) | Reuses the venv the repo already owns and feature 21 needs; matches the `lint-ansible` skill's local behaviour exactly | One `pip install` per CI run (cacheable); no image layer; weaker default hermeticity than a frozen image (closed by locking - see below) | Chosen - severs the Docker / `retry.sh` / `versions.env` / version-getter dependencies cleanly |
| Dockerised composite (move as-is) | Byte-for-byte identical behaviour; strongest reproducibility (frozen transitive closure) | Drags `Dockerfile` + `retry.sh` + its classifiers/strategies + a `versions.env` entry + `get-ansible-lint-version.sh` into Common-Ansible, duplicating the retry primitive across two repos and running a container alongside molecule's own | Rejected - re-homes cross-cutting plumbing that has no other consumer here |

#### The hermeticity trade-off and how it is closed

A frozen Docker image is the more hermetic boundary: it bakes the exact
ansible-lint version *and its full transitive closure* (ansible-core,
cryptography, ruamel.yaml, the Python interpreter) at build time, so a run
is reproducible byte-for-byte given only Docker. A bare venv is weaker by
default - `pip install` re-resolves the transitive closure at run time, so
anything not explicitly pinned can float between runs. This is the one
real axis on which venv trails Docker, and the decision does not wave it
away; it closes it:

- **Lock the transitive closure**, not just the top-level line. The venv
  install uses a fully pinned, hash-locked requirement set (a compiled
  lockfile), so ansible-lint's dependencies are frozen the way an image
  layer would freeze them. Pinning `ansible-lint==<version>` alone is
  insufficient and is explicitly not the bar.
- **Pin the interpreter** via `setup-python` so the Python minor version
  is fixed rather than inherited from the runner image.

With both in place the venv's reproducibility is on par with the image for
practical purposes, without a second container beside molecule's
docker-in-docker.

Note this is also a correctness *gain* over the old image: that image
pinned ansible-lint but pulled ansible-core *transitively at build time*,
so it linted against a floating ansible-core that could differ from the
repo's pinned `ansible-core==2.18.1` and the collections molecule and
production actually use. The venv lints against the one real toolchain.

#### Runner-environment gating and the controller provider

The venv must be *provisioned*, and the estate already has one pattern for
that: Common-DotNet's `ci-dotnet.yml` installs its toolchain through a
`provision-dotnet-toolchain` composite **gated on `runner.environment`** -
run it on `github-hosted` runners (which lack the toolchain), skip it on
`self-hosted` runners, "where Infrastructure-GitHubRunners bakes the
toolchain in". ci-ansible follows the same rule so the two domains
provision consistently:

- **`github-hosted`**: install the hash-locked closure into a
  `setup-python` interpreter (the inline path). This is the only path that
  needs a fresh install.
- **`self-hosted`**: reuse the already-provisioned controller rather than
  installing a second copy. The reuse goes through the estate's controller
  SSOT, `ops/bootstrap-controller-consumer.sh` (venv + ansible-core +
  ansible-lint + collections), which locates-or-ensures the shared
  controller and is a no-op when the runner already has it baked in. That
  script reaches the substrate bootstrap via `pwsh.exe`/WSL - a Windows
  entry point - which is exactly why it belongs on the self-hosted path
  and not on a bare ubuntu-hosted image.

Gating is on `runner.environment`, not a runner label, for the reason
ci-dotnet documents: a self-hosted pool is targeted by an arbitrary custom
label that no inspection could classify as hosted-or-not.

Consequences of the venv choice:

- The version pin moves from `versions.env`'s `ANSIBLE_LINT_VERSION` into
  Common-Ansible's pinned requirement set (`ansible-lint==<version>` plus
  the hash-locked closure), its existing single source of truth for
  Ansible-toolchain versions.
- `retry.sh` is not needed: a `pip install` failure is retried by pip and
  the network, and there is no image build to wrap. `retry.sh` and its
  classifiers/strategies stay in Common-Automation for their other
  consumers; nothing is copied.
- The auto-skip (no `ansible.cfg`/`playbooks/`/`roles/` -> `::notice::`
  and exit 0) and the consumer-config-vs-bundled-`production` resolution
  are preserved; only the invocation underneath changes from `docker run`
  to a direct `ansible-lint` call.

### Decision: scope - full migration

This feature carries the move end to end in one sequenced pass, not a
partial stand-up: it creates `ci-ansible.yml` in Common-Ansible, rewires
all three Ansible consumers to it, removes the ansible-lint step and
deletes the composite (and its orphaned lib deps) from Common-Automation,
and updates the local pre-push runners on both sides. The ordering is
constrained so no repo ever loses ansible-lint coverage on `master` (see
[Risks and sequencing](#risks-and-sequencing)).

### Chosen direction

ansible-lint moves into a reusable workflow owned by Common-Ansible and
consumed only by repos with Ansible content, run from the controller venv.
The pinned version (in `requirements.txt`) and the default ruleset (the
bundled `ansible-lint.config.yml`) stay single-sourced in Common-Ansible,
so the three Ansible repos share one definition rather than forking it.
Common-Automation is left strictly tech-agnostic, with the Ansible
composite and its Docker/retry/version plumbing removed.

## Relationship to feature 21

This feature and [feature 21](../21-molecule-ci-in-common-ansible/problem.md)
(molecule CI) are companions: both move Ansible-domain CI into
Common-Ansible for the same charter reason, and both need the same
substrate-sibling wiring so a consumer's playbooks/roles resolve the
Common-Ansible substrate roles by short name in CI (the consumer repo
checks out Common-Ansible alongside and puts its `roles/` on
`ANSIBLE_ROLES_PATH`). Decided: the two share **one** reusable workflow,
`ci-ansible.yml`, not two. Feature 20 (the lighter of the pair - no
container test run) creates `ci-ansible.yml` with ansible-lint as its
first gate and establishes the shared sibling-checkout wiring; feature 21
adds molecule to the same workflow as a second, path-gated job and
supplies its scenario setup. ansible-lint first, molecule second.

## Constraints

- Master-only branches across all affected repos.
- The ansible-lint ruleset and version pin remain single-sourced (no
  per-repo fork); after the move the ruleset lives in Common-Ansible's
  bundled `ansible-lint.config.yml` and the version in Common-Ansible's
  `requirements.txt`.
- The venv install is reproducible: the ansible-lint dependency closure is
  hash-locked (not just a top-level `==` pin) and the Python interpreter is
  pinned via `setup-python`, so the gate is not weaker than the frozen
  image it replaces (see
  [The hermeticity trade-off](#the-hermeticity-trade-off-and-how-it-is-closed)).
- Cross-repo blast radius: removing the step from Common-Automation's
  `ci-yaml.yml` and rewiring each Ansible consumer must land in an order
  that never leaves an Ansible repo without ansible-lint coverage on
  `master`.
- README sections are earned per step and kept in the structured index.
- ASCII only; prose and comments wrap at the repo's column conventions.

## Risks and sequencing

- An ordering hazard: if Common-Automation drops the step before the
  consumers consume the new Common-Ansible workflow, those repos lose
  ansible-lint coverage in the gap. The plan sequences the new workflow
  onto Common-Ansible's `master` and rewires consumers before the
  Common-Automation step is removed.
- A consumer that resolves substrate roles by short name will fail lint
  if the sibling checkout / `ANSIBLE_ROLES_PATH` wiring is absent; this is
  the same wiring feature 21 needs and must be shared, not duplicated.
- Removing the step from the shared `ci-yaml.yml` is a change to a
  contract every repo consumes; non-Ansible repos must be confirmed
  unaffected (they only lose a step that always skipped for them).

## Out of scope

- Replacing or reconfiguring the ansible-lint ruleset/profile (this is a
  relocation, not a rule change).
- The molecule CI gate - that is
  [feature 21](../21-molecule-ci-in-common-ansible/problem.md).
- Any change to the cross-cutting linters (`yamllint`, `actionlint`,
  `action-validator`, `shellcheck`) or their home in Common-Automation.
