# Plan: ansible-lint CI in Common-Ansible

Implementation plan for the migration described in
[problem.md](./problem.md). Read that first - this file does not repeat
the rationale, the two locked decisions (controller venv; full
migration), or the survey.

## Index

- [Conventions and sequencing](#conventions-and-sequencing)
- [Cross-repo ordering (no coverage gap)](#cross-repo-ordering-no-coverage-gap)
- [Section 1 - Common-Ansible: stand up the venv ansible-lint gate](#section-1---common-ansible-stand-up-the-venv-ansible-lint-gate)
  - [Step 1.1 - Pin and hash-lock the lint toolchain](#step-11---pin-and-hash-lock-the-lint-toolchain)
  - [Step 1.2 - Bundled default config + venv helper + unit tests](#step-12---bundled-default-config--venv-helper--unit-tests)
  - [Step 1.3 - Composite action wrapping the helper](#step-13---composite-action-wrapping-the-helper)
  - [Step 1.4 - The `ci-ansible.yml` reusable workflow](#step-14---the-ci-ansibleyml-reusable-workflow)
  - [Step 1.5 - Local pre-push parity](#step-15---local-pre-push-parity)
  - [Step 1.6 - README for the gate](#step-16---readme-for-the-gate)
  - [Step 1.7 - Gate provisioning on `runner.environment`; reuse the controller provider](#step-17---gate-provisioning-on-runnerenvironment-reuse-the-controller-provider)
  - [Step 1.8 - Preserve the consumer nested-slice lint shim](#step-18---preserve-the-consumer-nested-slice-lint-shim)
  - [Step 1.9 - Extend the gate to substrate-composing consumers (Vm-Provisioner)](#step-19---extend-the-gate-to-substrate-composing-consumers-vm-provisioner)
- [Section 2 - Consumers adopt `ci-ansible.yml`](#section-2---consumers-adopt-ci-ansibleyml)
  - [Step 2.1 - Infrastructure-Vm-Users](#step-21---infrastructure-vm-users)
  - [Step 2.2 - Infrastructure-GitHubRunners](#step-22---infrastructure-githubrunners)
- [Section 3 - Common-Automation: remove the old gate and plumbing](#section-3---common-automation-remove-the-old-gate-and-plumbing)
  - [Step 3.1 - Remove the ansible-lint step from `ci-yaml.yml`](#step-31---remove-the-ansible-lint-step-from-ci-yamlyml)
  - [Step 3.2 - Delete the composite action tree](#step-32---delete-the-composite-action-tree)
  - [Step 3.3 - Remove orphaned lib dependencies](#step-33---remove-orphaned-lib-dependencies)
  - [Step 3.4 - Drop ansible-lint from the local lint runner](#step-34---drop-ansible-lint-from-the-local-lint-runner)
  - [Step 3.5 - README and doc cleanup](#step-35---readme-and-doc-cleanup)
- [Section 4 - Infrastructure-Vm-Provisioner: first-time gate](#section-4---infrastructure-vm-provisioner-first-time-gate)
  - [Step 4.1 - Add the root shim and thin caller (composer)](#step-41---add-the-root-shim-and-thin-caller-composer)
- [Section 5 - Verify and close](#section-5---verify-and-close)
  - [Step 5.1 - Cross-repo coverage verification](#step-51---cross-repo-coverage-verification)

## Conventions and sequencing

- Each step is the smallest committable act, states why it exists, names
  its tests, and carries a diagram of the components it touches.
- Master-only branches. Every step lands on `master` in its own repo
  before a later step in another repo depends on it.
- ASCII only; comments wrap at the repo's column conventions. README
  sections are earned per step (no trailing docs pass).
- "Green locally" for this repo means the relevant subset of
  `scripts/run-tests.sh` (bats via `run-bats-tests`, yamllint via
  `lint-yaml`, and - after Step 1.5 - ansible-lint via the new local
  step) plus `actionlint` / `action-validator` on any changed workflow.

## Cross-repo ordering (no coverage gap)

The only hard constraint the sequence must honour: no Ansible repo may
sit on `master` without an ansible-lint gate at any point. Common-
Automation's step is therefore the **last** thing removed, after every
consumer already gets the gate from Common-Ansible.

```mermaid
flowchart LR
  subgraph S1["Section 1 - Common-Ansible"]
    A["ci-ansible.yml on master<br/>(self-triggers on its own PRs)"]
  end
  subgraph S2["Section 2 - Consumers"]
    B["Vm-Users + GitHubRunners<br/>add ci-ansible caller"]
  end
  subgraph S3["Section 3 - Common-Automation"]
    C["remove ansible-lint step<br/>+ delete composite/lib"]
  end
  subgraph S4["Section 4 - Vm-Provisioner"]
    VP["add root shim + composer caller<br/>(first-ever gate)"]
  end
  subgraph S5["Section 5"]
    D["verify: every Ansible repo<br/>gated, no orphan refs"]
  end
  A -->|"Common-Ansible now double-<br/>covered (old + new)"| B
  B -->|"own-roles consumers on new gate"| C
  C -->|"old gate gone -> shim can land<br/>without re-triggering it"| VP
  VP --> D
  linkStyle 0,1,2,3 stroke:#2a2
```

Coverage state after each section (ci-ansible = ansible-lint runs against
it via the new gate):

| Repo | Start | After S1 | After S2 | After S3 | After S4 |
| --- | --- | --- | --- | --- | --- |
| Common-Ansible | ci-yaml | ci-yaml + ci-ansible | ci-yaml + ci-ansible | ci-ansible | ci-ansible |
| Vm-Users | ci-yaml | ci-yaml | ci-yaml + ci-ansible | ci-ansible | ci-ansible |
| GitHubRunners | ci-yaml | ci-yaml | ci-yaml + ci-ansible | ci-ansible | ci-ansible |
| Vm-Provisioner | (skips) | (skips) | (skips) | (skips) | ci-ansible (new) |
| non-Ansible repos | ci-yaml (skips) | (skips) | (skips) | no step | no step |

No cell is ever empty for an already-covered Ansible repo - the transition
is additive-then-subtractive. Vm-Provisioner is the one deliberate
addition, and it is sequenced last: it auto-skipped the old gate (no root
`ansible.cfg`), so it carries no coverage to preserve, and its enabling
root shim would re-trigger the old gate (identical root-`ansible.cfg`
detection) if the two ever coexisted. Section 4 therefore adds its shim and
composer caller only *after* Section 3 removes the old gate, bringing its
substrate-composing playbook under the new gate for the first time (see
[Section 4](#section-4---infrastructure-vm-provisioner-first-time-gate); the
workflow capability it relies on lands earlier in
[Step 1.9](#step-19---extend-the-gate-to-substrate-composing-consumers-vm-provisioner)).

The S1 -> S2 edge carries a prerequisite gate: Steps 1.7-1.9 must be on
Common-Ansible `master` before Section 2. The consumers keep their Ansible
content in a nested `hyper-v/ubuntu/Ansible/` slice, so until ci-ansible
reuses the self-hosted controller (1.7), stops overriding an own-roles
consumer's root `ansible.cfg` shim (1.8), and gains the substrate-composer
branch (1.9), a consumer's `ci-ansible` call cannot go green.

## Section 1 - Common-Ansible: stand up the venv ansible-lint gate

### Step 1.1 - Pin and hash-lock the lint toolchain

**Why.** The venv decision moves the version pin from Common-Automation's
`versions.env` into Common-Ansible, and the
[hermeticity constraint](./problem.md#the-hermeticity-trade-off-and-how-it-is-closed)
requires the full dependency closure be hash-locked, not just a top-level
`==` pin. This step is the reproducibility foundation every later CI/local
run installs from.

**What.**

- Introduce a compiled, hashed requirement set for the controller venv:
  a human-edited `requirements.in` (sources: `ansible-core`,
  `ansible-lint`) compiled with `pip-compile --generate-hashes` into the
  existing `requirements.txt` (now the fully-pinned, `--hash`-annotated
  lockfile). Keep the current explanatory header.
- Teach the venv bootstrap to enforce the lock: change
  [`ops/_bootstrap-controller-wsl.sh`](../../../../ops/_bootstrap-controller-wsl.sh)
  line ~134 to `pip install --require-hashes -r requirements.txt`, so a
  drifted or unhashed line fails loudly rather than floating.
- **Resolve the ansible-lint / ansible-core compatibility** (a real
  decision, not a mechanical pin): the current CI value is
  `ansible-lint==26.4.0`, but the venv pins `ansible-core==2.18.1`, and
  recent ansible-lint majors raise their `ansible-core` floor. During
  execution, `pip-compile` will surface the constraint; the **default
  resolution is to keep `ansible-core==2.18.1` unchanged and pin the
  newest ansible-lint line that resolves against it** (do not bump
  ansible-core - that would perturb the collections and the molecule/
  target toolchain, which is out of scope per problem.md). If no
  reasonably-recent ansible-lint line supports 2.18.1, stop and raise the
  ansible-core bump as a separate decision rather than making it silently.

**Tests.**

- Bootstrap the venv from a clean `.venv`; assert
  `pip install --require-hashes -r requirements.txt` succeeds (proves the
  closure is fully hashed and self-consistent).
- Assert `.venv/bin/ansible-lint --version` prints the pinned version and
  `.venv/bin/ansible --version` still prints `2.18.1` (proves co-install).
- Extend the existing bootstrap bats coverage (if the pinned-versions
  summary is asserted there) to include the ansible-lint line.

```mermaid
flowchart TD
  IN["requirements.in<br/>ansible-core, ansible-lint"] -->|"pip-compile<br/>--generate-hashes"| LOCK["requirements.txt<br/>(pinned + hashes)"]
  LOCK -->|"--require-hashes"| BOOT["_bootstrap-controller-wsl.sh"]
  BOOT --> VENV[".venv/bin/{ansible,ansible-lint}"]
  COMPAT{"ansible-lint line<br/>resolves vs<br/>ansible-core 2.18.1?"} -->|yes| IN
  COMPAT -->|no| ESCALATE["stop: raise ansible-core<br/>bump as separate decision"]
```

### Step 1.2 - Bundled default config + venv helper + unit tests

**Why.** The auto-skip and consumer-config-vs-bundled-`production`
resolution are behaviour that must survive the move; only the invocation
underneath changes from `docker run` to a direct `ansible-lint` call. A
single helper keeps CI and local identical (the SSOT the old composite
had).

**What.**

- Add the bundled default config
  `.github/actions/ansible-lint/ansible-lint.config.yml` - the strict
  `production` profile. Port it from Common-Automation but correct the
  staging-dir note: the `exclude_paths` keep `.github/` (covered by
  actionlint / action-validator) and replace the `.common-automation/`
  entry with `.common-ansible/` (the sibling-checkout dir this workflow
  introduces in Step 1.4).
- Add the venv helper `.github/actions/ansible-lint/ansible-lint.sh`:
  - Auto-skip: no `ansible.cfg` / `playbooks/` / `roles/` at the target
    root -> `::notice::` + exit 0.
  - Consumer-config resolution: a repo-root `.ansible-lint[.yml|.yaml]`
    wins; else pass `-c <bundled config>`.
  - Invoke `ansible-lint --project-dir <target> [--force-color]
    [-c <config>]` from PATH (venv activated by the caller). No docker, no
    `retry.sh`, no version getter, no `--user`/mount plumbing.
- No dependency on `.github/lib` (Common-Ansible has none) - the helper is
  self-contained plus the adjacent config.

**Tests.** Port the docker-free bats cases and add a venv guard mirroring
the old `require_docker`:

- `auto-skips when no Ansible content exists` (no venv needed).
- `auto-skips when only unrelated YAML is present`.
- `exits 0 on a minimal valid playbook` - `require_ansible_lint` skip when
  `.venv/bin/ansible-lint` is absent.
- `exits non-zero on a playbook with a known violation`.
- `honours a consumer-supplied .ansible-lint config` (profile `min`).
- The three docker-build **retry** cases are **not ported** - the retried
  artifact (image build) no longer exists (recorded as a deliberate
  coverage reduction in the [test note](#step-16---readme-for-the-gate)).

```mermaid
flowchart TD
  START["ansible-lint.sh (target dir)"] --> SKIP{"ansible.cfg /<br/>playbooks/ / roles/?"}
  SKIP -->|no| NOTE["::notice:: skipping<br/>exit 0"]
  SKIP -->|yes| CFG{"repo-root<br/>.ansible-lint*?"}
  CFG -->|yes| CONSUMER["use consumer config"]
  CFG -->|no| BUNDLED["-c ansible-lint.config.yml<br/>(production)"]
  CONSUMER --> RUN["ansible-lint --project-dir<br/>(from venv PATH)"]
  BUNDLED --> RUN
```

### Step 1.3 - Composite action wrapping the helper

**Why.** Mirror the established composite pattern (every other lint gate
is a `uses:`-able composite) so the workflow's self/consumer branching in
Step 1.4 is uniform, and so the helper stays the single invocation both CI
and local share.

**What.**

- Add `.github/actions/ansible-lint/action.yml` - a `composite` that runs
  `ansible-lint.sh` from `${{ github.action_path }}`, expecting the venv
  already on PATH (the workflow puts it there in Step 1.4). Description
  states it lints the caller repo and auto-skips on no Ansible content;
  no `${{ }}` in the `description` field (composite manifests evaluate it
  at load time).

**Tests.** `action-validator` on the new `action.yml`; the helper's own
behaviour is already covered by Step 1.2's bats.

```mermaid
flowchart LR
  WF["ci-ansible.yml step"] -->|uses| ACT["action.yml (composite)"]
  ACT -->|runs| SH["ansible-lint.sh"]
  ENV["venv on PATH<br/>(set by workflow)"] -.-> SH
```

### Step 1.4 - The `ci-ansible.yml` reusable workflow

**Why.** The Ansible-domain workflow this whole feature exists to create.
It also establishes the **shared sibling-checkout + `ANSIBLE_ROLES_PATH`
wiring** that [feature 21](../21-molecule-ci-in-common-ansible/problem.md)
reuses for molecule - so this step owns that wiring, not feature 21.

**What.** Add `.github/workflows/ci-ansible.yml`, modelled on Common-
Automation's `ci-yaml.yml` (same runner-selection precedence: `runner`
input -> `CI_ANSIBLE_RUNNER` caller variable -> `ubuntu-latest`; same
`pull_request` + `workflow_dispatch` + `workflow_call` triggers so it
self-triggers on its own PRs and is callable by consumers). One `ansible`
job:

1. Check out the caller repo.
2. **Stage the Common-Ansible sibling** into `.common-ansible/` via a
   conditional sparse checkout (`ref: master`, paths: `.github/actions`,
   `requirements.txt`, `requirements.yml`, `ansible.cfg`, `roles`) - only
   when `github.repository != Klark-Morrigan/Common-Ansible`. This gives a
   consumer the pinned toolchain, the bundled config, and the substrate
   `roles/` for short-name resolution. (Self runs use its own workspace.)
3. `actions/setup-python` pinned to the interpreter minor (3.12) - the
   [hermeticity](./problem.md#the-hermeticity-trade-off-and-how-it-is-closed)
   interpreter pin.
4. `pip install --require-hashes -r <self-or-sibling>/requirements.txt`,
   then put the resulting `bin/` on `$GITHUB_PATH`.
5. `ansible-galaxy collection install -r <...>/requirements.yml` (parity
   with local; needed by feature 21's molecule that reuses this wiring).
6. Export `ANSIBLE_ROLES_PATH` as `<caller>/roles:.common-ansible/roles`
   (consumer) or `<self>/roles` (self), the same short-name resolution
   `ops/_ansible-env.sh` encodes.
7. Run the ansible-lint composite - self branch `./.github/actions/ansible-lint`,
   consumer branch `./.common-ansible/.github/actions/ansible-lint` - each
   `if:`-guarded on `github.repository`, matching `ci-yaml.yml`'s
   local-`./`-refs rationale (eager registry resolution vs step-time
   local resolution).

**Tests.** `actionlint` + `action-validator` on the new workflow; then a
live PR against Common-Ansible exercises the **self** branch end-to-end
(the roles in this repo lint clean under `production`, or the failures are
triaged per the `lint-ansible` skill's noqa guidance). The consumer branch
is exercised in Section 2.

```mermaid
flowchart TD
  subgraph JOB["ci-ansible.yml : job 'ansible'"]
    CO["checkout caller"] --> STAGE{"repo ==<br/>Common-Ansible?"}
    STAGE -->|no| SIB["sparse-checkout Common-Ansible<br/>-> .common-ansible/"]
    STAGE -->|yes| SELF["use own workspace"]
    SIB --> PY["setup-python 3.12"]
    SELF --> PY
    PY --> PIP["pip install --require-hashes<br/>+ venv onto GITHUB_PATH"]
    PIP --> GAL["ansible-galaxy collection install"]
    GAL --> RP["export ANSIBLE_ROLES_PATH<br/>(caller:substrate)"]
    RP --> LINT["ansible-lint composite<br/>(self / consumer branch)"]
  end
  FEAT21["feature 21 molecule job"] -.->|"reuses steps<br/>2-6 (shared wiring)"| RP
```

### Step 1.5 - Local pre-push parity

**Why.** Common-Ansible's local lint (`scripts/run-lint-yaml-and-bash.sh`)
delegates to Common-Automation's `_run-lint-yaml-and-bash.sh`, which
Section 3 strips of its ansible-lint step. Without a replacement, this
repo's own pre-push run would stop linting its roles. Item 5 of
[problem.md](./problem.md#what-is-changing) requires a venv-based local
step matching the `lint-ansible` skill.

**What.**

- Add `scripts/run-lint-ansible.sh`: activate `.venv` and run the Step 1.2
  helper against the repo root (auto-skips cleanly if the venv or Ansible
  content is absent). This is the local twin of the composite - same
  helper, same config resolution.
- Wire it into `scripts/run-lint-yaml-and-bash.sh` so a full local lint
  run still covers ansible-lint after the delegated Common-Automation half
  drops it. Order it after the delegated call; track its failure in the
  same summary style.

**Tests.** Run `scripts/run-lint-yaml-and-bash.sh` locally; assert the
ansible-lint step runs against this repo's `roles/` and the overall run is
green (or surfaces only pre-existing, triaged findings).

```mermaid
flowchart LR
  RUN["scripts/run-lint-yaml-and-bash.sh"] --> DELEG["Common-Automation<br/>_run-lint-yaml-and-bash.sh<br/>(yaml/actionlint/... - no ansible-lint)"]
  RUN --> LOCAL["scripts/run-lint-ansible.sh"]
  LOCAL -->|"source .venv +"| SH["ansible-lint.sh (Step 1.2)"]
```

### Step 1.6 - README for the gate

**Why.** Document the new gate where it now lives, per the earned-section
rule.

**What.** Add a README section to Common-Ansible covering: the
`ci-ansible.yml` reusable workflow and how a consumer wires it; the venv
execution model and the hash-locked requirement set (link
problem.md's hermeticity subsection); the bundled `production` default and
consumer-config override; and a short note that the docker-build **retry**
tests were dropped with the docker path (the deliberate coverage
reduction). Keep the repo README's structured index in sync.

**Tests.** `lint-yaml` / markdown-lint parity as the repo already applies;
link-check the new anchors.

```mermaid
flowchart LR
  README["Common-Ansible README"] --> SEC["Ansible CI section:<br/>ci-ansible, venv model,<br/>lockfile, config, retry note"]
  SEC -.->|links| PROB["problem.md<br/>hermeticity subsection"]
```

### Step 1.7 - Gate provisioning on `runner.environment`; reuse the controller provider

**Why.** The toolchain the gate needs must be *provisioned*, and the
estate has one pattern for that: Common-DotNet's `ci-dotnet.yml`
provisions through a composite **gated on `runner.environment`** - install
on `github-hosted` (bare image), skip on `self-hosted` because
Infrastructure-GitHubRunners bakes the toolchain in. ci-ansible must
provision the same way, so a self-hosted run reuses the one controller the
estate single-sources via `ops/bootstrap-controller-consumer.sh` instead
of installing a second, divergent copy.

**What.** The `ansible` job's toolchain provisioning branches on
`runner.environment`, retaining the self/consumer repository split (four
combinations, matching ci-dotnet):

- **`github-hosted` (both repo branches):** install the hash-locked
  closure into a `setup-python` interpreter - `setup-python` +
  `pip install --require-hashes` + `ansible-galaxy` (the provisioning
  [Step 1.4](#step-14---the-ci-ansibleyml-reusable-workflow) sets up). The
  controller provider does not run here: it reaches the substrate
  bootstrap through `pwsh.exe`/WSL (a Windows entry point) absent on a
  bare ubuntu image, so the inline hash-locked install is the hosted-path
  provisioner and the hermeticity boundary.
- **`self-hosted` (consumer):** reuse the baked controller via
  `ops/bootstrap-controller-consumer.sh <consumer-ansible-slice-root>`
  from the staged substrate (`.common-ansible/ops/...`), which
  locates-or-ensures the shared controller venv and is a no-op when the
  runner already carries it. No `setup-python` / `pip` / `galaxy` on this
  path.
- **`self-hosted` (self = Common-Ansible):** the provider is the
  consumer-side entry, so Common-Ansible's own self-hosted runs assert the
  repo's `.venv` is present (its own `bootstrap-controller` owns building
  it) and reuse it.
- Whichever branch runs puts the provisioned toolchain on `$GITHUB_PATH` -
  the `setup-python` scripts dir (hosted) or the controller `.venv/bin`
  (self-hosted) - so the ansible-lint composite resolves `ansible-lint`
  from the single provisioned toolchain.
- The gate keys on `runner.environment`, **not** a runner label (a
  self-hosted pool carries an arbitrary custom label no inspection can
  classify), per the rationale ci-dotnet documents.

**Tests.**

- `actionlint` / `action-validator` on the workflow.
- Hosted path: the Common-Ansible self PR on `ubuntu-latest` lints green.
- Self-hosted path: a `workflow_dispatch` with
  `runner: ["self-hosted", ...]` (or the `CI_ANSIBLE_RUNNER` variable set
  on a consumer) confirms the provider-reuse branch runs, `ansible-lint`
  resolves from the baked controller, and no `setup-python`/`pip` step
  executes.

The `<consumer-ansible-slice-root>` handed to the provider is the nested
slice, not the repo root (see [Step 1.8](#step-18---preserve-the-consumer-nested-slice-lint-shim)
for how the consumers' nested layout is resolved for the lint pass).

```mermaid
flowchart TD
  JOB["ci-ansible : job 'ansible'"] --> ENVQ{"runner.environment?"}
  ENVQ -->|github-hosted| HOST["setup-python +<br/>pip --require-hashes +<br/>galaxy (Step 1.4)"]
  ENVQ -->|self-hosted| REPOQ{"repo ==<br/>Common-Ansible?"}
  REPOQ -->|yes self| SELFV["assert own .venv,<br/>reuse"]
  REPOQ -->|no consumer| PROV["bootstrap-controller-consumer.sh<br/>&lt;slice-root&gt; (reuse baked controller)"]
  HOST --> PATH["toolchain bin -> GITHUB_PATH"]
  SELFV --> PATH
  PROV --> PATH
  PATH --> LINT["ansible-lint composite"]
  PROV -.->|slice-root, see Step 1.8| SLICE["nested slice:<br/>hyper-v/ubuntu/Ansible"]
```

### Step 1.8 - Preserve the consumer nested-slice lint shim

**Why.** The consumers keep their Ansible content in a nested
`hyper-v/ubuntu/Ansible/` slice and already resolve it for linting with a
root `ansible.cfg` **lint-support shim** (`roles_path =
hyper-v/ubuntu/Ansible/roles`). That shim is built against a fixed
contract: ansible-lint activates on the root `ansible.cfg`, runs with
`--project-dir` = repo root, and resolves short-name `include_role`
through the cfg's `roles_path`. The gate must honour that contract.
Exporting `ANSIBLE_ROLES_PATH` as an environment variable does not: the
env var overrides the cfg `roles_path`, so a value of
`${GITHUB_WORKSPACE}/roles` - a path these nested consumers do not have -
clobbers the shim and the nested roles stop resolving. The prior Common-
Automation gate linted these consumers green precisely because it set no
such env var and let the shim govern.

**What.**

- The ansible-lint pass does not export an `ANSIBLE_ROLES_PATH` that
  overrides a caller's root `ansible.cfg`. Each repo's root cfg governs
  roles resolution during lint: Common-Ansible's real cfg
  (`roles_path = roles`, root-level content) on self runs; the consumers'
  lint-support shim (`roles_path = <nested>/roles`) on consumer runs. The
  composite already lints with `--project-dir` = repo root and
  auto-activates on the root cfg, so no per-slice path plumbing is needed.
- The substrate sibling checkout stays - the composite reads the bundled
  config and the pinned toolchain from it - but for an **own-roles**
  caller the lint job exports no roles path: the caller's cfg already
  resolves its own roles, and its content does not statically require the
  substrate at syntax-check time (the old gate linted these green with no
  substrate on the path). A **substrate-only composer** is the exception
  and is handled in [Step 1.9](#step-19---extend-the-gate-to-substrate-composing-consumers-vm-provisioner);
  molecule's own converge-time roles-path (feature 21) is separate again.
- Relying on the root cfg is sound in CI: a GitHub checkout is ordinary
  ext4, not the `/mnt/c` drvfs mount that makes Ansible ignore a
  world-writable `ansible.cfg`. The env-var mirror `ops/_ansible-env.sh`
  needs locally is a drvfs artefact that does not apply on a runner.

**Tests.**

- A consumer dispatch (Vm-Users or GitHubRunners) lints green, the root
  shim resolving the nested `include_role` short names.
- Negative check: setting `ANSIBLE_ROLES_PATH=${GITHUB_WORKSPACE}/roles`
  reproduces the load-failure, proving the shim (not an env override)
  carries these consumers.
- The Common-Ansible self run stays green (its root cfg is unaffected).

```mermaid
flowchart TD
  LINT["ansible-lint --project-dir = repo root"] --> REPOQ{"caller"}
  REPOQ -->|self: Common-Ansible| RC["root ansible.cfg (real)<br/>roles_path = roles"]
  REPOQ -->|consumer| SH["root ansible.cfg (lint shim)<br/>roles_path = hyper-v/ubuntu/Ansible/roles"]
  RC --> OK["short-name roles resolve"]
  SH --> OK
  ENV["ANSIBLE_ROLES_PATH env override"]:::bad -.->|"clobbers cfg -><br/>nested roles lost"| SH
  classDef bad stroke:#c33,stroke-dasharray:4 4,color:#c33
```

### Step 1.9 - Extend the gate to substrate-composing consumers (Vm-Provisioner)

**Why.** Infrastructure-Vm-Provisioner is an Ansible consumer the other
steps do not cover: its nested slice holds one playbook
(`provision-toolchains.yml`) that `import_role`s the substrate roles
`jdk`, `dotnet_sdk`, `dotnet_tools` and **ships no roles of its own**, and
it has **no root `ansible.cfg`**, so it auto-skips the gate today - that
playbook is unlinted. It composes the substrate the same way it does at
runtime (via `ops/bootstrap-controller.sh` -> the controller provider).
Bringing it under the gate is a small, deliberate coverage addition, but
it needs a resolution rule the own-roles consumers do not: because
`import_role` is static, ansible-lint's `syntax-check` must resolve those
substrate roles, so the substrate roles have to be on the path during
lint - the one case where a lint run legitimately needs them.

**What.** This step adds the **substrate-composer branch** to the reusable
`ci-ansible.yml` - the workflow *capability* a composer needs. The
Vm-Provisioner repo-side adoption that exercises it (its root shim, its
thin caller, its local parity) lands later, in
[Section 4](#section-4---infrastructure-vm-provisioner-first-time-gate),
after Section 3 removes the old gate (the shim would otherwise re-trigger
it - see the [ordering section](#cross-repo-ordering-no-coverage-gap)).

The branch completes the roles-resolution contract by caller shape:

- **Own-roles caller** (Common-Ansible self; Vm-Users, GitHubRunners): the
  caller's root `ansible.cfg` (real or shim) governs `roles_path`; the job
  exports nothing (Step 1.8). Unchanged by this step.
- **Substrate-only composer** (Vm-Provisioner): the job puts the staged
  substrate roles (`.common-ansible/roles`) on `ANSIBLE_ROLES_PATH`. This
  does **not** reintroduce the Step 1.8 clobber, because the composer has
  no own-roles cfg to override - the substrate path is the only source,
  and is required.

Concretely, in the reusable workflow:

- The workflow distinguishes composer from own-roles by an explicit signal
  from the thin caller (a `with:` input on the `ci-ansible` call declaring
  the slice composes substrate roles, `composes-substrate-roles`) rather
  than fragile filesystem sniffing. When that input is set, the composer
  step exports `ANSIBLE_ROLES_PATH = <staged substrate>/roles`; otherwise
  nothing is exported and the own-roles branch governs.
- No consumer sets the input yet, so the branch is inert on `master` until
  Section 4's caller opts in - it does not affect the own-roles consumers
  or the Common-Ansible self run.

**Tests.**

- `actionlint` / `action-validator` on the changed workflow.
- Regression: with no caller setting the composer input, the own-roles
  consumers (Vm-Users, GitHubRunners) and the Common-Ansible self run are
  unaffected - still cfg-governed, no substrate on their lint path (the new
  branch stays inert).
- The composer branch itself is exercised end-to-end in
  [Section 4](#section-4---infrastructure-vm-provisioner-first-time-gate),
  once Vm-Provisioner opts in.

```mermaid
flowchart TD
  LINT["ansible-lint --project-dir = repo root"] --> SHAPE{"caller shape"}
  SHAPE -->|own-roles| CFG["root ansible.cfg governs<br/>(job exports nothing) - Step 1.8"]
  SHAPE -->|substrate-only composer| COMP["job puts .common-ansible/roles<br/>on ANSIBLE_ROLES_PATH"]
  CFG --> OK["short-name roles resolve"]
  COMP --> OK
  COMP -.->|resolves| SUBR["jdk, dotnet_sdk, dotnet_tools<br/>(substrate)"]
```

## Section 2 - Consumers adopt `ci-ansible.yml`

Prerequisite: Section 1 merged to Common-Ansible `master` (the reusable
workflow and composite must be resolvable at `@master`).

This section covers the two **own-roles** consumers. The substrate-only
composer, Vm-Provisioner, adopts the gate in
[Section 4](#section-4---infrastructure-vm-provisioner-first-time-gate) -
after Section 3, so its enabling shim never coexists with the old gate.

### Step 2.1 - Infrastructure-Vm-Users

**Why.** Move this consumer onto the new gate while `ci-yaml.yml` still
runs (double coverage - zero-gap per the
[ordering table](#cross-repo-ordering-no-coverage-gap)).

**What.**

- Add `.github/workflows/ci-ansible.yml` - a thin caller:
  `uses: Klark-Morrigan/Common-Ansible/.github/workflows/ci-ansible.yml@master`,
  `name: Common-Ansible`, `on: [pull_request, workflow_dispatch]`.
- Update the existing `ci-yaml.yml` header comment: it currently claims
  four parallel lint jobs including ansible-lint; correct it to the three
  cross-cutting linters and note the Ansible gate now comes from
  Common-Ansible's `ci-ansible.yml`.

**Tests.** `actionlint` / `action-validator` on the new workflow; a PR run
confirms the `ansible` job runs green against this repo's Ansible content
via the consumer (sibling-checkout) branch established in Step 1.4.

```mermaid
flowchart LR
  VU["Vm-Users<br/>ci-ansible.yml (thin)"] -->|uses @master| CA["Common-Ansible<br/>ci-ansible.yml (reusable)"]
  VU2["Vm-Users<br/>ci-yaml.yml (unchanged wiring,<br/>comment corrected)"] --> COMMON["Common-Automation<br/>ci-yaml.yml"]
```

### Step 2.2 - Infrastructure-GitHubRunners

**Why / What / Tests.** Identical to Step 2.1 for the
Infrastructure-GitHubRunners repo (same thin caller, same header-comment
correction, same PR verification). Kept a separate step so each consumer
lands and is verified independently.

```mermaid
flowchart LR
  GR["GitHubRunners<br/>ci-ansible.yml (thin)"] -->|uses @master| CA["Common-Ansible<br/>ci-ansible.yml (reusable)"]
```

## Section 3 - Common-Automation: remove the old gate and plumbing

Prerequisite: Section 2 merged - every consumer the old gate covered
(Common-Ansible via self-trigger, Vm-Users, GitHubRunners) now gets
ansible-lint from Common-Ansible on `master`. Vm-Provisioner was never
covered by the old gate (it auto-skipped), so it needs no coverage before
this removal; it is gated afterwards in
[Section 4](#section-4---infrastructure-vm-provisioner-first-time-gate).
Only now is it safe to remove the old gate.

### Step 3.1 - Remove the ansible-lint step from `ci-yaml.yml`

**Why.** The gate is re-homed and every consumer already has it; the step
in the universal workflow is now the domain leak problem.md set out to
remove. No repo loses coverage (ordering table, "After S3" column).

**What.** In Common-Automation `.github/workflows/ci-yaml.yml` delete both
`ansible-lint (self)` and `ansible-lint (consumer)` steps and their
trailing comment block; update the workflow's top-of-file description
(currently "four complementary surfaces") to the three that remain.

**Tests.** `actionlint` / `action-validator`; a PR run confirms the
`yaml` job passes with three linters and no ansible-lint step.

```mermaid
flowchart TD
  CY["Common-Automation ci-yaml.yml"] --> Y["yamllint"] --> AL["actionlint"] --> AV["action-validator"]
  AL2["ansible-lint (self+consumer)"]:::del
  AV --> AL2
  classDef del stroke:#c33,stroke-dasharray:4 4,color:#c33
```

### Step 3.2 - Delete the composite action tree

**Why.** Dead once Step 3.1 stops referencing it; leaving it invites a
second source of truth to drift from Common-Ansible's copy.

**What.** Delete `.github/actions/ansible-lint/` in Common-Automation
(`action.yml`, `ansible-lint.sh`, `Dockerfile`, `ansible-lint.config.yml`,
`README.md`, `ansible-lint.bats`).

**Tests.** Repo bats suite green; `grep -r ansible-lint .github` returns
nothing outside historical docs; `action-validator` still green (one fewer
action).

```mermaid
flowchart LR
  DIR[".github/actions/ansible-lint/<br/>action.yml, .sh, Dockerfile,<br/>config, README, bats"]:::del
  classDef del stroke:#c33,stroke-dasharray:4 4,color:#c33
```

### Step 3.3 - Remove orphaned lib dependencies

**Why.** `get-ansible-lint-version.sh` and the `versions.env`
`ANSIBLE_LINT_VERSION` entry existed **only** for the composite (verified:
their sole non-doc consumers were the deleted composite/Dockerfile).
`retry.sh` is **kept** - it has many live consumers (actionlint,
action-validator, yamllint, changelog).

**What.**

- Delete `.github/lib/get-ansible-lint-version.sh` and
  `get-ansible-lint-version.bats`.
- Remove `ANSIBLE_LINT_VERSION` (and its yamllint cross-check comment)
  from `.github/lib/versions.env`.
- Update Common-Automation `README.md` where it references the ansible-
  lint version getter / composite.
- Leave `retry.sh`, its classifiers, and strategies untouched.

**Tests.** `grep -r "ANSIBLE_LINT_VERSION\|get-ansible-lint-version"`
returns nothing outside `.git` / `graphify-out` / historical docs; the
remaining `get-*-version` bats suites pass; the retry bats suite passes.

```mermaid
flowchart TD
  subgraph DELETE["delete (composite-only consumers)"]
    G["get-ansible-lint-version.sh + .bats"]:::del
    V["versions.env: ANSIBLE_LINT_VERSION"]:::del
  end
  subgraph KEEP["keep (other live consumers)"]
    R["retry.sh + classifiers + strategies"]
  end
  R -.->|"used by"| U["actionlint, action-validator,<br/>yamllint, changelog"]
  classDef del stroke:#c33,stroke-dasharray:4 4,color:#c33
```

### Step 3.4 - Drop ansible-lint from the local lint runner

**Why.** `_run-lint-yaml-and-bash.sh` calls the deleted helper; leaving
`run_ansible_lint` would break every local lint run in Common-Automation
and every repo that delegates to it (including Common-Ansible, which now
runs its own via Step 1.5).

**What.** In `scripts/_run-lint-yaml-and-bash.sh` remove the
`run_ansible_lint` function, its `if ! run_ansible_lint` call site, and
its failure-tracking entry; update the file header's linter list.

**Tests.** Run `scripts/_run-lint-yaml-and-bash.sh` against Common-
Automation itself (no Ansible content) and confirm it no longer references
ansible-lint and stays green; confirm a delegating repo's
`run-lint-yaml-and-bash.sh` still runs.

```mermaid
flowchart LR
  RUN["_run-lint-yaml-and-bash.sh"] --> KEEP["shellcheck, +x, actionlint,<br/>action-validator, yamllint"]
  RUN --> DROP["run_ansible_lint"]:::del
  classDef del stroke:#c33,stroke-dasharray:4 4,color:#c33
```

### Step 3.5 - README and doc cleanup

**Why.** Keep Common-Automation's docs truthful: it is now strictly the
cross-cutting linters, and its charter statement is vindicated rather than
contradicted.

**What.** In Common-Automation `README.md` (and any composite index),
remove ansible-lint from the actions list / the ci-yaml linter
enumeration, and add a one-line pointer that Ansible linting now lives in
Common-Ansible's `ci-ansible.yml`. Keep the structured index in sync.

**Tests.** `lint-yaml` / markdown parity; link-check.

```mermaid
flowchart LR
  RM["Common-Automation README"] --> DROP["ansible-lint action + version getter<br/>(removed from lists)"]:::del
  RM --> PTR["pointer -> Common-Ansible ci-ansible.yml"]
  classDef del stroke:#c33,stroke-dasharray:4 4,color:#c33
```

## Section 4 - Infrastructure-Vm-Provisioner: first-time gate

Prerequisite: Section 3 merged - Common-Automation's old ansible-lint gate
is gone from both `ci-yaml.yml` and the local engine. Only now can
Vm-Provisioner's root `ansible.cfg` shim land without re-triggering that
gate (which shares the shim's root-`ansible.cfg` detection and cannot
resolve the composer's substrate roles). The reusable workflow's
substrate-composer branch ([Step 1.9](#step-19---extend-the-gate-to-substrate-composing-consumers-vm-provisioner))
is already on Common-Ansible `master`.

### Step 4.1 - Add the root shim and thin caller (composer)

**Why.** Infrastructure-Vm-Provisioner is the one Ansible consumer with no
gate today: its nested slice holds a single playbook
(`provision-toolchains.yml`) that `import_role`s the substrate roles `jdk`,
`dotnet_sdk`, `dotnet_tools`, ships no roles of its own, and has no root
`ansible.cfg`, so it auto-skipped the old gate. This step gives it its
first-ever ansible-lint pass, via the composer branch Step 1.9 built - and
does so only after Section 3, so the enabling shim never coexists with the
old gate it would otherwise break.

**What.**

- Add a root `ansible.cfg` lint-support shim to Vm-Provisioner so
  ansible-lint activates on it instead of auto-skipping. It carries no
  `roles_path` of its own (an empty `[defaults]` is enough to trigger
  activation); role resolution comes from the job, since the composed roles
  are substrate not present in this repo, and a `roles_path` here would be
  clobbered by the composer's `ANSIBLE_ROLES_PATH` anyway.
- Add `.github/workflows/ci-ansible.yml` - a thin caller:
  `uses: Klark-Morrigan/Common-Ansible/.github/workflows/ci-ansible.yml@master`,
  `name: Common-Ansible`, `on: [pull_request, workflow_dispatch]`, passing
  the composer signal (`composes-substrate-roles: true`) so the staged
  substrate roles land on `ANSIBLE_ROLES_PATH` for `syntax-check`.
- Update the existing `ci-yaml.yml` header comment (the "four parallel lint
  jobs including ansible-lint" claim) to the three cross-cutting linters,
  noting the Ansible gate now comes from `ci-ansible.yml`.
- Keep local lint parity: a local ansible-lint run for Vm-Provisioner must
  also see the substrate roles. Its runtime bridge already resolves
  `consumer:substrate` on `ANSIBLE_ROLES_PATH` (`ops/_ansible-env.sh`), so
  the local path is wired the same way. (Common-Automation's delegated
  local engine no longer runs ansible-lint after
  [Step 3.4](#step-34---drop-ansible-lint-from-the-local-lint-runner), so
  the composer's local pass comes through this substrate-aware path, not
  the old docker gate.)

**Tests.**

- `actionlint` / `action-validator` on the new workflow.
- A PR / dispatch lints `provision-toolchains.yml` green via the composer
  branch (its first-ever ansible-lint pass), with `jdk` / `dotnet_sdk` /
  `dotnet_tools` resolving from the staged substrate.
- Negative check: with the substrate off the path, `syntax-check` fails
  with `role 'jdk' not found`, proving the composer branch is what carries
  it.
- Regression: the own-roles consumers and the Common-Ansible self run stay
  green (unaffected - they set no composer input).

```mermaid
flowchart LR
  VP["Vm-Provisioner<br/>ansible.cfg shim +<br/>ci-ansible.yml (composer signal)"] -->|uses @master| CA["Common-Ansible<br/>ci-ansible.yml (reusable)"]
  CA -->|"composes-substrate-roles: true"| RP["staged substrate roles/<br/>on ANSIBLE_ROLES_PATH"]
  RP -->|resolves| SUBR["jdk, dotnet_sdk, dotnet_tools"]
```

## Section 5 - Verify and close

### Step 5.1 - Cross-repo coverage verification

**Why.** The migration's success criterion is behavioural, not textual:
every Ansible repo is still gated, no non-Ansible repo carries a dead
step, and nothing references the deleted plumbing. This step proves it
before the feature is called done.

**What.**

- Confirm on `master` for each of Common-Ansible, Vm-Users,
  GitHubRunners, Vm-Provisioner that a PR triggers the `ci-ansible /
  ansible` check and it runs (not skips) against real Ansible content -
  for Vm-Provisioner via the composer branch (its first-ever lint pass).
- Confirm no non-Ansible repo carries a dead ansible-lint step and its
  `ci-yaml` still passes.
- Confirm no repo references `Common-Automation/.github/actions/ansible-lint`
  or `ANSIBLE_LINT_VERSION` any longer.
- Finalize the feature README index entry and mark the checklist in this
  plan complete.

**Tests.** The four consumer PR runs above are the test; plus a
cross-repo `grep` sweep for the removed identifiers returning empty.

```mermaid
flowchart TD
  V["Step 5.1 verification"] --> CA["Common-Ansible: ci-ansible runs"]
  V --> VU["Vm-Users: ci-ansible runs"]
  V --> GR["GitHubRunners: ci-ansible runs"]
  V --> VP["Vm-Provisioner: ci-ansible runs<br/>(composer branch, first lint)"]
  V --> GREP["grep sweep: no orphan refs"]
```
