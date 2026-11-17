# Problem: Molecule CI in Common-Ansible

## Index

- [Summary](#summary)
- [Background](#background)
- [What feature 20 already landed](#what-feature-20-already-landed)
- [Scenario readiness](#scenario-readiness)
- [What is changing](#what-is-changing)
- [Why this belongs in Common-Ansible](#why-this-belongs-in-common-ansible)
- [Solution approach](#solution-approach)
  - [Off-the-shelf survey - the test framework](#off-the-shelf-survey---the-test-framework)
  - [Off-the-shelf survey - the CI host](#off-the-shelf-survey---the-ci-host)
  - [Decision: a needs-gated job, not an inline step](#decision-a-needs-gated-job-not-an-inline-step)
  - [Decision: presence-gating, not path-gating](#decision-presence-gating-not-path-gating)
  - [Decision: where the base images come from](#decision-where-the-base-images-come-from)
  - [Chosen direction](#chosen-direction)
- [Relationship to feature 20](#relationship-to-feature-20)
- [Constraints](#constraints)
- [Risks and sequencing](#risks-and-sequencing)
- [Out of scope](#out-of-scope)

## Summary

The Ansible roles in this estate ship molecule scenarios under
`Tests/molecule/<role>/<scenario>/` (converge, idempotence, verify, plus
reconcile and remove directions), but **no CI workflow runs them**.
Feature 20 landed `ci-ansible.yml`, the Ansible-domain reusable workflow,
and it runs `ansible-lint` only; nothing in CI or in
`scripts/run-tests.sh` invokes molecule. Molecule is the only check that
exercises a role's real behaviour on a running OS; everything gated today
is static (`ansible-lint`, `yamllint`). So a role that lints clean and is
valid YAML but does the wrong thing on a real machine - e.g. applies to
every host instead of the one matching `vmName` - ships undetected.

This feature closes that gap by adding molecule to the existing
`ci-ansible.yml`, reusing the toolchain and substrate-staging scaffold
feature 20 built for exactly this purpose.

## Background

- Each role carries molecule scenarios that use the Docker driver: a
  `default` scenario (apply the role, re-apply to prove idempotence,
  verify the resulting system state), usually a `remove` scenario (apply,
  tear down, verify the artifacts are gone), and for several roles a
  `reconcile` scenario. Common-Ansible alone has 18 scenarios across 8
  roles (`docker`, `dotnet_sdk`, `dotnet_tools`, `jdk`, `powershell`,
  `toolchain_apt`, `toolchain_bats_libs`, `toolchain_host_push`).
- Molecule is installed in Common-Ansible's controller venv
  (`.venv/bin/molecule`), and the repo owns `ansible-core`, the pinned
  Galaxy collections, and the controller bootstrap.
- The `run-molecule-tests` skill drives a single scenario locally and is
  the only place molecule runs today; `scripts/run-tests.sh` does not
  invoke it, and neither does any workflow.
- Consumer repos (Infrastructure-Vm-Users, Infrastructure-GitHubRunners)
  consume Common-Ansible's substrate roles by short name; their molecule
  scenarios reference both the consumer's own roles and the substrate
  roles, so resolving short names at converge time needs the
  Common-Ansible sibling on `ANSIBLE_ROLES_PATH`.

## What feature 20 already landed

This problem was first written before `ci-ansible.yml` existed. It now
does, and most of the scaffold this feature was going to need is already
in place and documented as being for this feature's benefit:

- **The workflow itself.** `.github/workflows/ci-ansible.yml`, reusable,
  triggered on `pull_request` / `workflow_call` / `workflow_dispatch`,
  with a runner-selection chain (`runner` input, then the caller's
  `CI_ANSIBLE_RUNNER` variable, then `["ubuntu-latest"]`).
- **Substrate staging.** A consumer run sparse-checks-out Common-Ansible
  at `master` into `.common-ansible/` (`.github/actions`, `ops`,
  `requirements.txt`, `requirements.yml`, `ansible.cfg`, `roles`), and a
  `substrate` step resolves the substrate root once (`.` on self runs,
  `.common-ansible` on consumer runs).
- **Toolchain provisioning**, gated on `runner.environment`: the
  `github-hosted` path pins Python 3.12 and installs the hash-locked
  closure from `requirements.txt`; the `self-hosted` path reuses the
  pre-baked controller (consumers via
  `ops/bootstrap-controller-consumer.sh`, Common-Ansible via an assert on
  its own `.venv`). Either way the toolchain bin lands on `$GITHUB_PATH`.
- **Galaxy collections.** `ansible-galaxy collection install -r
  requirements.yml` runs on the hosted path, with the header noting it is
  "required by feature 21's molecule that reuses this wiring".

What feature 20 deliberately did **not** do is export an
`ANSIBLE_ROLES_PATH` for own-roles callers, because that env var
overrides a caller's root `ansible.cfg` `roles_path` and would clobber
the consumers' nested-slice lint shim. Molecule's converge-time roles
path is this feature's concern and must be scoped to the molecule
surface, never leaked back onto the lint step.

## Scenario readiness

The original version of this document recorded two defects that blocked
any CI adoption - no `python3` on a bare `ubuntu:24.04` target, and a
fragile relative `roles_path` that molecule resolved against its
ephemeral run directory. **Both are fixed in the scenarios as they stand
today:**

- Targets now run on purpose-built base images rather than the bare
  Ubuntu image. `Tests/molecule/toolchain_host_push/Dockerfile` bakes
  `python3`, `sudo`, `tar`, `gzip` and is shared by most scenarios;
  `Tests/molecule/docker/Dockerfile` bakes `systemd`, `systemd-sysv`,
  `python3`, `sudo` for the one scenario that needs a real init and a
  running daemon. Each Dockerfile documents why in its header.
- `roles_path` is gone from the scenarios. Each `molecule.yml` sets
  `provisioner.env.ANSIBLE_ROLES_PATH` to
  `${MOLECULE_PROJECT_DIRECTORY}/../../../roles`, which resolves against
  the scenario directory and propagates across every molecule phase.

What replaced them is a different, CI-specific prerequisite: those base
images are **built locally by hand** (each Dockerfile header carries its
`docker build -t ...` command), and every scenario consumes the resulting
tag via `pre_build_image: true`. A fresh runner has no such tag and no
registry to pull it from, so the images must be produced as part of the
CI run. That is now the concrete prerequisite work, in place of the
python/roles-path repairs.

## What is changing

1. `ci-ansible.yml` gains a `molecule` job that `needs:` the existing
   `ansible` (lint) job, so molecule only runs once lint is green.
2. The job discovers `Tests/molecule/<role>/<scenario>/molecule.yml` in
   the caller's workspace and **skips entirely when there are none**, the
   same presence-gating philosophy the ansible-lint composite already
   applies to Ansible content.
3. Discovered scenarios fan out over a matrix so wall-clock is the
   slowest scenario, not their sum.
4. The scenarios' base images are built in the run before any scenario
   executes.
5. The job puts both the caller's and the staged substrate's `roles/` on
   `ANSIBLE_ROLES_PATH` for converge-time short-name resolution - scoped
   to this job only, leaving feature 20's lint step's deliberate absence
   of that export untouched.
6. `ci-ansible.yml`'s header comments, which currently forward-reference
   "feature 21's molecule job", are brought in line with what actually
   ships.

## Why this belongs in Common-Ansible

Molecule is Ansible-domain tooling, and unlike the previously dockerised
`ansible-lint` composite it cannot be a tech-agnostic black box: it drags
`ansible-core`, `molecule`, `molecule-plugins[docker]`, the pinned Galaxy
collections, the role source under test, and the Docker driver. Placing
it in Common-Automation would pull an entire language ecosystem into a
repo whose charter is to carry none ("outside any single language
ecosystem ... without dragging tooling along").

Common-Ansible already owns exactly that toolchain - the controller venv,
`ansible-core`, the collection pins - and feature 20 already wired CI
access to it. Adding molecule beside the lint gate reuses that wiring
instead of re-deriving it, and keeps Ansible-domain CI owned by the
Ansible repo.

## Solution approach

### Off-the-shelf survey - the test framework

| Option | Source / license | Fit | Notes |
| --- | --- | --- | --- |
| **molecule** + `molecule-plugins[docker]` | OSS, MIT, Ansible community | Purpose-built for role converge/idempotence/verify against a container; 18 scenarios already authored and locally green | Keep - already adopted |
| `ansible-test` | OSS, GPL-3.0 | Built for collection sanity/integration, not standalone role scenario lifecycles | Wrong granularity |
| Testinfra / goss alone | OSS | Assertion layer only; no converge/idempotence lifecycle or driver management | Already available as molecule's verifier; not a replacement |
| Bare `ansible-playbook` + manual asserts | In-repo | Reinvents create/converge/idempotence/destroy orchestration | Rejected |

Decision: keep molecule. The scenarios exist and pass locally; this
feature is about running them in CI, not about the framework.

### Off-the-shelf survey - the CI host

| Option | Fit | Notes |
| --- | --- | --- |
| GitHub-hosted `ubuntu-latest` | Docker preinstalled; the runner is a VM, so the `docker` scenario's privileged container works | Default, inherited from feature 20's runner-selection chain |
| Self-hosted runner | Needs the Docker daemon and tolerates privileged containers; a containerised runner may not | Available via the same `CI_ANSIBLE_RUNNER` variable feature 20 reads |

### Decision: a needs-gated job, not an inline step

Feature 20's `ansible` job is deliberately one job of sequential steps -
one PR status check, and an implicit `success()` guard so a failing step
short-circuits the rest. The obvious reading is that molecule should
simply be a later step in it. With 18 scenarios that does not survive
contact with wall-clock:

| Option | Fit | Cost | Notes |
| --- | --- | --- | --- |
| Inline step in the `ansible` job | Keeps exactly one status check; lint-gating is free via the implicit `success()` guard | Scenarios run strictly sequentially. 18 scenarios, several of which install a JDK or the .NET SDK into a container, put a PR gate in the tens of minutes | Rejected on wall-clock |
| **Separate `molecule` job with `needs: ansible` + matrix** | `needs:` reproduces the lint gate explicitly; matrix makes wall-clock the slowest single scenario; per-scenario failures are individually named | A second status check row, plus one row per matrix leg; the toolchain provisioning steps are re-run in the new job | Chosen |
| Separate workflow file | Full independence | Duplicates feature 20's staging + provisioning wiring, the exact duplication feature 20's header set out to prevent | Rejected |

`needs: ansible` gives the same "only if lint passed" semantics the
inline step would have, without serialising the container runs behind it.
The cost is that the new job re-runs substrate staging and toolchain
provisioning, since jobs share no filesystem - accepted, because those
steps are cheap relative to a converge and the alternative is the
sequential penalty.

### Decision: presence-gating, not path-gating

The original plan was a `paths:` filter on `roles/**` and
`Tests/molecule/**`. That is not available here: `ci-ansible.yml` is a
reusable workflow, so the caller owns the trigger and a `paths:` filter
on the callee does not apply. The available analogue is the one lint
already uses - the ansible-lint composite auto-skips when the caller has
no Ansible content. Molecule mirrors it: a discovery step globs
`Tests/molecule/*/*/molecule.yml` in the caller's workspace and emits the
matrix; an empty result skips the matrix job entirely, so a repo with no
scenarios pays nothing.

Gating additionally on *changed* paths (skip when a PR touches no role or
scenario) is a further optimisation requiring an explicit diff check. It
is deliberately not bundled here; presence-gating is what makes the gate
correct, changed-path gating only makes it cheaper.

### Decision: where the base images come from

`pre_build_image: true` consumes a locally-tagged image that exists on a
developer machine only because the Dockerfile header's build command was
run by hand.

| Option | Fit | Notes |
| --- | --- | --- |
| **Build in-run from the in-repo Dockerfiles** | No registry, no auth, no publish step; the image definition stays the single source of truth it already is | Costs one `apt-get install` layer build per run unless cached; the build must be single-sourced (a script both CI and the local skill call) rather than a command duplicated into the workflow |
| Publish to GHCR and pull | Build cost paid once | Adds a publishing pipeline, registry auth, and a tag-freshness question the Dockerfiles currently do not have |
| Inline the packages into a `prepare.yml` | No image build at all | Re-introduces the exact failure the Dockerfiles were written to fix: the first `ansible.builtin.*` task needs an interpreter that `prepare.yml` cannot yet install |

Building in-run is chosen; extracting the two build commands into a
script that the workflow and the `run-molecule-tests` skill both call is
part of the work, so the build stays single-sourced.

### Chosen direction

Add a `molecule` job to `ci-ansible.yml`, `needs:`-gated behind the
existing lint job, presence-gated on discovered scenarios and skipped
when there are none, fanning out over a per-scenario matrix. It reuses
feature 20's substrate staging and toolchain provisioning, builds the
scenario base images from the in-repo Dockerfiles via a single-sourced
script, and exports a converge-time `ANSIBLE_ROLES_PATH` covering both
the caller's and the staged substrate's `roles/` - scoped to this job, so
the lint job's deliberate absence of that export is preserved. Consumed
by Common-Ansible and the role-owning consumers (Infrastructure-Vm-Users,
Infrastructure-GitHubRunners).

## Relationship to feature 20

[Feature 20](https://github.com/Klark-Morrigan/Common-Ansible/issues/20)
(ansible-lint) and this feature both move Ansible-domain CI into
Common-Ansible, and the two share **one** reusable workflow,
`ci-ansible.yml`. Feature 20 shipped: it established the workflow with
ansible-lint as its first gate and landed the substrate staging,
runner-environment-gated toolchain provisioning, and Galaxy collection
install that this feature reuses rather than duplicates. This feature
adds molecule to that same workflow as a second job gated behind the
lint job. ansible-lint first, molecule second.

The one place the two must stay separate is `ANSIBLE_ROLES_PATH`.
Feature 20 established that the lint pass must not export it for an
own-roles caller (it would clobber the consumers' nested-slice lint
shim, `roles_path = hyper-v/ubuntu/Ansible/roles`); its lone exception is
a substrate-only composer, which has no own-roles cfg to clobber.
Molecule's need is different - converge-time resolution of short-name
roles across caller and substrate - and lives entirely within the
molecule job.

## Constraints

- Master-only branches across all affected repos.
- Molecule scenarios stay with the role they test (substrate scenarios in
  Common-Ansible; consumer scenarios in the consumer repo); only the
  workflow is centralised.
- The substrate staging and toolchain provisioning wiring is reused from
  feature 20, not duplicated in a second workflow file.
- The molecule job's `ANSIBLE_ROLES_PATH` export is scoped to that job;
  the lint job's deliberate non-export is preserved.
- The scenario base-image build is single-sourced between CI and the
  local `run-molecule-tests` path, not a command copied into the
  workflow.
- Container cost is contained by presence-gating and per-scenario matrix
  parallelism; a repo with no scenarios must run nothing.
- README sections are earned per step and kept in the structured index.
- ASCII only; prose and comments wrap at the repo's column conventions.

## Risks and sequencing

- The scenarios pass locally but have never run on a hosted runner; the
  first green CI run is itself a deliverable, and the base-image build is
  sequenced before the job is wired as a required check.
- The `docker` role's scenario runs a privileged, systemd-init container
  with an inner Docker daemon (docker-in-docker). That works on a
  GitHub-hosted runner because the runner is a VM; a containerised
  self-hosted runner may not permit it. Defaulting to the hosted runner
  avoids it, with `CI_ANSIBLE_RUNNER` left as the override.
- Making molecule a required check while a scenario is flaky would block
  merges; the plan introduces it as non-blocking until proven green
  across all scenarios, then promotes it.
- Consumer scenarios depend on the substrate sibling checkout; an
  ordering gap (substrate not yet on `master`) breaks short-name
  resolution - the same cross-repo ordering feature 19's Section 10 and
  feature 20 manage.
- A matrix leg per scenario multiplies status rows on every Ansible PR.
  If that proves noisy, the fallback is fewer, coarser legs (one per
  role rather than per scenario), not a return to a sequential step.

## Out of scope

- Authoring new molecule scenarios for roles that lack them (this feature
  runs the existing scenarios; coverage expansion is separate).
- Changed-path gating on top of presence-gating (see
  [Decision: presence-gating](#decision-presence-gating-not-path-gating)).
- The ansible-lint gate - that is
  [feature 20](https://github.com/Klark-Morrigan/Common-Ansible/issues/20).
- Any change to Common-Automation's cross-cutting linters or their home.
- Replacing molecule or its docker driver.
