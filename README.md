# Infrastructure-Vm-Users

> **Notice:** This repo is no longer the operator default;
> [Common-Ansible] is. The PowerShell scripts here remain
> callable and back the Infrastructure-E2E `custom-powershell` users
> flow as a non-primary first-class implementation. The canonical home
> of the migrated logic is under [Common-Ansible]'s
> `docs/dev/implementation/02-...` (create direction) and `03-...`
> (remove direction) folders.

Reconciles and removes OS users on Ubuntu Hyper-V VMs against a desired
state stored in a local encrypted vault.

## Index

- [What this repo does](#what-this-repo-does)
- [What it does not do](#what-it-does-not-do)
- [Requirements](#requirements)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Config reference](#config-reference)
- [Reconciliation behaviour](#reconciliation-behaviour)
- [Removal](#removal)
- [Cross-process timing (opt-in)](#cross-process-timing-opt-in)
- [Consuming Common-Ansible](#consuming-common-ansible)
- [CI](#ci)
- [Repo structure](#repo-structure)

---

## What this repo does

Reads two vaults:

| Vault | Secret | Source |
|---|---|---|
| `VmProvisioner` | `VmProvisionerConfig` | [Infrastructure-Vm-Provisioner] |
| `VmUsers` | `VmUsersConfig` | `setup-secrets.ps1` in this repo |

Joins them by `vmName`, then for each reachable VM reconciles:

1. **OS groups** - ensures declared groups exist before users are processed;
   supports optional GID pinning (`groupadd`).
2. **OS users** - creates or updates shell, home directory, and supplementary
   groups (`useradd` / `usermod`).
3. **Sudoers rules** - writes or removes `/etc/sudoers.d/{username}`, always
   validated with `visudo -c -f` before going live.

---

## What it does not do

- Provision VMs - use [Infrastructure-Vm-Provisioner] for that.
- Delete users automatically on config removal - use `remove-users.ps1`
  explicitly when you intend to remove accounts (see [Removal](#removal)).
- Move home directories - if `homeDir` changes in config, the directory on
  disk is not relocated (a manual step to avoid data loss).
- Manage SSH keys or PAM configuration.

---

## Requirements

PowerShell 7+ (`pwsh`).

---

## Prerequisites

- **Windows 11** with PowerShell 7+.
- **[Infrastructure-Vm-Provisioner]** has already run - the `VmProvisioner`
  vault and its VMs must exist.
- The **admin user on each VM can run sudo without a password prompt** - SSH
  authentication uses the password from the `VmProvisioner` vault, but once
  connected, sudo must not require a second password entry. This is the
  default for Ubuntu cloud images provisioned with cloud-init (set up
  automatically via `/etc/sudoers.d/90-cloud-init-users`).
- An internet connection on first run (PSGallery is used to install
  `Common.PowerShell`, `Infrastructure.Secrets`, and `Posh-SSH`
  automatically). Posh-SSH is used as the carrier for its bundled
  SSH.NET library; its own cmdlets are not used directly.

---

## Quick start

### 1. Store the config (once per machine)

```powershell
.\hyper-v\ubuntu\shared\setup-secrets.ps1 -ConfigFile C:\private\vm-users-config.json
```

Re-running safely updates the stored config.

### 2. Reconcile users

```powershell
.\hyper-v\ubuntu\PowerShell\create-users.ps1
```

The script is idempotent - re-running it produces the same result and emits
`ok` for everything already in the desired state.

### 3. Remove users

```powershell
.\hyper-v\ubuntu\PowerShell\remove-users.ps1
```

Reads the same `VmUsersConfig` used by `create-users.ps1` and removes every
declared user, their sudoers file, and declared groups from each reachable VM.
See [Removal](#removal) for the sequence and safety guarantees.

---

## Config reference

`VmUsersConfig` is a JSON array - one object per VM, matched to the
provisioner config by `vmName`.

```jsonc
[
  {
    // Must match a vmName in VmProvisionerConfig exactly.
    "vmName": "ubuntu-01-ci",
    // Optional. Declares groups that must exist before users are reconciled.
    // Useful for documenting intent and ensuring groups are created even if
    // no users in this config are members (e.g. a shared directory group
    // managed by Infrastructure-GitHubRunners). Supports optional gid pinning
    // - see fields table below.
    //
    // Do NOT declare "docker" here with a pinned gid: that group is created
    // by Infrastructure-Vm-Provisioner's docker package with a distro-assigned
    // gid, and a conflicting pin fails the groups role. A user's "docker"
    // supplementary membership (below) resolves against that provisioner-
    // created group - as long as provisioning runs before this reconcile.
    "groups": [
      {
        "groupName": "u-actions-runner"
      }
    ],
    "users": [
      {
        "username": "u-actions-runner",
        // nologin prevents direct SSH login - this account is service-only.
        // Even if credentials were known, the shell rejects interactive
        // sessions. Consuming repos (e.g. Infrastructure-GitHubRunners)
        // act as this user only via sudoers delegation from u-runner-deploy.
        "shell":    "/usr/sbin/nologin",
        "homeDir":  "/home/u-actions-runner",
        // Supplementary groups. The primary group u-actions-runner is declared
        // in the groups section above; useradd adopts it via -g rather than
        // creating a new one. u-runner-deploy joins that primary group as a
        // supplementary member for write access.
        //
        // "docker" is required ONLY when this runner executes container-based
        // CI (the Common-Automation lint composites - actionlint, yamllint,
        // ansible-lint - run their linters in Docker and need the socket at
        // /var/run/docker.sock). This config is the single authority for the
        // grant: the users role sets groups with append:false, so a docker
        // membership added by any other repo is stripped on the next run.
        // Infrastructure-Vm-Provisioner installs the daemon and creates the
        // docker group; Infrastructure-GitHubRunners' register play asserts
        // this membership and fails fast if it is missing. Omit "docker" for
        // runners that never touch containers.
        "groups":       ["docker"],
        // Lines written verbatim to /etc/sudoers.d/{username}.
        // Empty list = file absent (removed if previously present).
        "sudoersRules": []
      },
      {
        "username": "u-runner-deploy",
        // Interactive shell - this account is the SSH entry point used by
        // consuming repos at deploy time. Admin credentials are never
        // required or stored outside the VmProvisioner vault.
        "shell":    "/bin/bash",
        "homeDir":  "/home/u-runner-deploy",
        // Joins u-actions-runner as a supplementary group so it can write
        // into /home/u-actions-runner/runners/ when that directory is set
        // g+rwx by Infrastructure-GitHubRunners. u-actions-runner owns the
        // directory via its primary group - no extra group entry needed there.
        "groups":   ["u-actions-runner"],
        // Optional. When present, written via chpasswd on every run.
        // Comparison against an existing hash is impossible, so overwriting
        // is the only safe approach. This vault entry is the canonical source
        // of the password - consuming repos read from here rather than
        // storing their own copy. Must never appear in console output or
        // SSH command arguments.
        "password": "...",
        // Scoped to exactly the operations Infrastructure-GitHubRunners
        // requires. SSH password auth is the only gate - once authenticated,
        // there is no further challenge before sudo. These rules bound the
        // blast radius: even if u-runner-deploy credentials are compromised,
        // the attacker cannot escalate beyond u-actions-runner or the
        // runner service lifecycle.
        //
        // Rules 1-5: act as u-actions-runner to manage files in its cache dir.
        //   mkdir/rm/curl/tar/test are scoped by binary only - sudoers cannot
        //   restrict by path argument without enabling bypass via symlinks.
        //   The constraint is that the attacker is bounded to whatever
        //   u-actions-runner itself can write.
        //   test is required because the runner user's home dir is mode 700;
        //   checking for a cached tarball must run as that user.
        // Rules 6-7: act as root to create /opt/runners/<name> and transfer
        //   ownership to u-actions-runner. /opt/runners is root-owned so the
        //   runner user cannot create directories there itself.
        // Rule 8: act as root to remove a runner directory under
        //   /opt/runners during deregistration. The wildcard matches one
        //   path component only (sudoers '*' does not match '/'), and
        //   rm refuses '.' and '..', so the blast radius is bounded to
        //   /opt/runners/<single-name>.
        // Rule 9: config.sh registers the runner; runs as u-actions-runner.
        // Rule 10: svc.sh installs/uninstalls the systemd unit; requires root.
        // Rules 11-13: systemctl lifecycle for the runner service.
        "sudoersRules": [
          "u-runner-deploy ALL=(u-actions-runner) NOPASSWD: /usr/bin/mkdir",
          "u-runner-deploy ALL=(u-actions-runner) NOPASSWD: /usr/bin/rm",
          "u-runner-deploy ALL=(u-actions-runner) NOPASSWD: /usr/bin/curl",
          "u-runner-deploy ALL=(u-actions-runner) NOPASSWD: /usr/bin/tar",
          "u-runner-deploy ALL=(u-actions-runner) NOPASSWD: /usr/bin/test",
          "u-runner-deploy ALL=(root) NOPASSWD: /usr/bin/mkdir",
          "u-runner-deploy ALL=(root) NOPASSWD: /usr/bin/chown",
          "u-runner-deploy ALL=(root) NOPASSWD: /usr/bin/rm -rf /opt/runners/*",
          "u-runner-deploy ALL=(u-actions-runner) NOPASSWD: /opt/runners/*/config.sh",
          "u-runner-deploy ALL=(root) NOPASSWD: /opt/runners/*/svc.sh",
          "u-runner-deploy ALL=(root) NOPASSWD: /bin/systemctl start actions.runner.*",
          "u-runner-deploy ALL=(root) NOPASSWD: /bin/systemctl stop actions.runner.*",
          "u-runner-deploy ALL=(root) NOPASSWD: /bin/systemctl is-active actions.runner.*"
        ]
      }
    ]
  }
]
```

### Required fields

| Field | Description |
|---|---|
| `vmName` | Hyper-V VM name - must match `VmProvisionerConfig` exactly |
| `users[].username` | OS username |
| `users[].shell` | Login shell (e.g. `/bin/bash`, `/usr/sbin/nologin`) |
| `users[].homeDir` | Absolute home directory path |
| `users[].groups` | Array of supplementary group names (may be empty) |
| `users[].sudoersRules` | Array of sudoers rule strings (may be empty) |

### Optional fields

| Field | Description |
|---|---|
| `groups` | Array of group declarations to ensure exist before users are processed |
| `groups[].groupName` | Group name (required within each group entry) |
| `groups[].gid` | Pin the GID - useful for NFS / Docker bind mounts; mismatch is an error |
| `users[].password` | OS password - always written via `chpasswd`; canonical source for consuming repos |

---

## Reconciliation behaviour

`create-users.ps1` is safe to re-run at any time. On each run:

1. VMs missing from `VmProvisionerConfig` are warned and skipped.
2. VMs that do not respond to ping are warned and skipped.
3. For each reachable VM, one SSH session is opened and all reconciliation
   runs within it.
4. **Group reconciliation** runs first. Declared groups are created if absent.
   If a group exists with a different GID than declared, the script throws an
   actionable error - GIDs are not silently changed because the numeric
   ownership stored on files would become stale.
5. **User reconciliation** compares shell and supplementary groups. `homeDir`
   is set only on creation - it is not moved if it changes later.
6. **Sudoers reconciliation** writes to a temp file, validates with
   `visudo -c -f`, then moves the file into place. If validation fails the
   live file is untouched and the script throws.

### Output legend

| Colour | Meaning |
|---|---|
| Cyan | In-progress step |
| Green | Already correct (`ok`) or newly created |
| Yellow | Updated or removed |
| Warning | Skipped (unmatched VM or unreachable) |
| Error | Fatal - script stops |

---

## Removal

`remove-users.ps1` is safe to re-run at any time. It reads the same
`VmUsersConfig` as `create-users.ps1` and removes every declared user and
group from each reachable VM. On each run:

1. VMs missing from `VmProvisionerConfig` are warned and skipped.
2. VMs that do not respond to ping are warned and skipped.
3. For each reachable VM, one SSH session is opened. For each declared user:
   1. **Sudoers removal** - `/etc/sudoers.d/{username}` is deleted if it
      exists. Absence is not an error.
   2. **User removal** - `userdel -r` deletes the account and home directory.
      The implicit primary group (named after the user) is removed
      automatically by `userdel`. Absence is not an error.
4. **Group removal** - declared groups are deleted after all users are gone
   so `groupdel` finds no members. If a group still has members (e.g. a
   user not in this config joined it), the group is warned and skipped rather
   than forcing deletion.

---

## Cross-process timing (opt-in)

Both `create-users.ps1` and `remove-users.ps1` run through one shared
orchestrator (`reconcile/common/Invoke-VmUserReconcileRun.ps1`) that times its
three stages - `Read configs + resolve router IP`, `Match + SSH-probe targets`,
and the per-VM SSH reconcile/removal (the final stage's label differs per
direction) - using the phase-timing shims from `Common.PowerShell`. The timing
is invisible to a direct operator run.

When the environment variable **`TIMING_TREE_OUTPUT_PATH`** is set, the
orchestrator also serialises the phase tree to that path (as schema-versioned
nested JSON) on both the success and failure paths. It does this with a single
`Export-PhaseTimingTreeIfRequested` call in its outer `finally`: that
self-guarding `Common.PowerShell` shim reads the variable and exports only when
it is set, so the guard and the contract name live once inside the shim rather
than being hand-written at each site. A parent orchestrator -
[Infrastructure-E2E] - sets it before shelling out and grafts the imported
tree under its "reconcile users" part, so an otherwise opaque shell-out span
gains its internal breakdown. The variable name is neutral: these scripts do
not know who consumes it. When it is unset, no file is written and behaviour
is unchanged.

---

## Consuming Common-Ansible

The Ansible migration of the user domain (feature 19) places the user
roles, playbooks, and operator wrappers in this repo - under the
`hyper-v/ubuntu/Ansible/` slice (the by-impl repo layout) - where they
consume [Common-Ansible] as shared substrate rather than re-implementing the
controller. The reusable roles (`groups`, `users`, `sudoers`, and the
`vm_users_entry` fact helper) live under [`roles/`](hyper-v/ubuntu/Ansible/roles/), the
operator playbooks under [`playbooks/`](hyper-v/ubuntu/Ansible/playbooks/) (shared posture in
[`docs/dev/playbook-conventions.md`](docs/dev/playbook-conventions.md)),
and the Ansible operator wrappers under [`ops/`](hyper-v/ubuntu/Ansible/ops/). This section
documents the reuse path that makes them work.

Common-Ansible is consumed as a **single sibling checkout**. Its roles
are not standalone - they read the dispatch bridge's extra-vars and
inventory contract - so the roles and the bridge are one substrate and
are taken together from one checked-out root, not split across
transports (a Galaxy collection was rejected for that reason; see
[Common-Ansible]'s README). The substrate root is resolved once by
[`ops/imports/_common-ansible-root.sh`](hyper-v/ubuntu/Ansible/ops/imports/_common-ansible-root.sh)
(the same adapter pattern the lint shims use for Common-Automation),
overridable with `COMMON_ANSIBLE_ROOT`:

| What is reused | How it is reached |
|---|---|
| The **controller + ops bridge** | `<root>/.venv` controller and `<root>/ops/` scripts, run in place |
| Any reusable **substrate roles** | `<root>/roles` is appended to `ANSIBLE_ROLES_PATH`, so a playbook can reference a substrate role by short name |

This repo's **own** user roles, playbook, and extra-vars fragment are
not reused from the substrate - they live here. The wrappers surface
them to the bridge by declaring `CA_CONSUMER_ROOT` (this repo's
`hyper-v/ubuntu/Ansible/` slice): the bridge then resolves the playbook from
here, puts this repo's
`roles/` **ahead of** the substrate `roles/` on `ANSIBLE_ROLES_PATH`
(so `groups` / `users` / `sudoers` resolve to this repo by short name),
and resolves the user extra-vars fragment from this repo's `ops/`. The
substrate carries no user domain; this repo owns it whole.

### Bootstrap

```bash
# From WSL, in the Ansible slice (or double-click
# hyper-v\ubuntu\Ansible\ops\bootstrap-controller.bat on Windows):
cd hyper-v/ubuntu/Ansible
ops/bootstrap-controller.sh
```

[`ops/bootstrap-controller.sh`](hyper-v/ubuntu/Ansible/ops/bootstrap-controller.sh) is a thin
shim: it resolves the Common-Ansible sibling (override with
`COMMON_ANSIBLE_ROOT`) and execs the substrate's shared consumer bootstrap
(`ops/bootstrap-controller-consumer.sh`), which makes sure the controller is
built - delegating to Common-Ansible's own bootstrap when its venv is absent.
That locate/build logic is a single source of truth in the substrate, shared
by every consumer. There is nothing to install for this repo - reusing the
substrate controller instead of forking it is the whole point of the Common-
split.

### Running the create / remove user flows

The Ansible flows are operator wrappers that declare what they need to
the substrate bridge and dispatch a repo-local playbook through it:

```bash
cd hyper-v/ubuntu/Ansible

# Reconcile groups, users, and sudoers on every provisioned VM:
SECRET_SUFFIX=Production ops/create-users.sh        # or ops\create-users.bat

# Remove sudoers, users, and groups (reverse order):
SECRET_SUFFIX=Production ops/remove-users.sh        # or ops\remove-users.bat
```

| Concern | Where it is handled |
|---|---|
| Vault / inventory / dispatch | The substrate bridge (`ops/_run-playbook.sh` in [Common-Ansible]), located via the root resolver |
| Which vaults to read | Declared by the wrapper via the `CA_*` contract (`CA_INVENTORY_VAULT=VmProvisioner`, `CA_EXTRA_VAULTS=VmUsers`) |
| Where the playbook / roles / fragment live | Declared by the wrapper as `CA_CONSUMER_ROOT` (this repo's `hyper-v/ubuntu/Ansible/` slice); the bridge resolves all three from here |
| Which lifecycle's secrets | `SECRET_SUFFIX` (e.g. `Production`) - required by the bridge; the wrapper does not default it |
| The user roles | `groups`, `users`, `sudoers` (and the `vm_users_entry` fact helper) under [`roles/`](hyper-v/ubuntu/Ansible/roles/), put ahead of the substrate `roles/` on the path |
| User extra-vars fragment | [`ops/_build-extra-vars-VmUsers.sh`](hyper-v/ubuntu/Ansible/ops/_build-extra-vars-VmUsers.sh) emits `vm_users_config`; the substrate composer derives it by the `_build-extra-vars-<Name>.sh` convention from the `VmUsers` vault and dispatches to it from `CA_CONSUMER_ROOT/ops` |

Forwarded arguments follow the bridge's playbook path, so `--tags`,
`--limit <vm>`, `--check`, and `-v` pass straight through to
`ansible-playbook`. The roles are covered by the molecule scenarios
under [`Tests/molecule/`](hyper-v/ubuntu/Ansible/Tests/molecule/) (Docker driver, one
`default` and one `remove` scenario per role).

### Smoke check

[`playbooks/smoke.yml`](hyper-v/ubuntu/Ansible/playbooks/smoke.yml) references a substrate role
by its short name (`groups`). With the sibling's roles on the path:

```bash
cd hyper-v/ubuntu/Ansible
# the Common-Ansible sibling is four levels above this slice:
ANSIBLE_ROLES_PATH="../../../../Common-Ansible/roles" \
  ansible-playbook --syntax-check playbooks/smoke.yml -i localhost,
```

A green check proves the scoped checkout resolves the substrate roles
from this repo (without the sibling on the roles path it fails with "the
role 'groups' was not found"). It is a resolution proof, not an execution
run - the substrate roles mutate a target host, so their behaviour is
exercised by molecule and integration tests, not a controller-side smoke.

### Prerequisite

A Common-Ansible sibling checkout under the same parent (e.g.
`..\Common-Ansible`) supplies both the controller/ops bridge and the
roles. Merge substrate changes to Common-Ansible's `master` before the
consumer relies on them.

---

## CI

CI runs on pull requests targeting `master` via `.github/workflows/ci.yml`,
which delegates to the shared reusable workflow in
[Common-PowerShell](https://github.com/Klark-Morrigan/Common-PowerShell):

```
Klark-Morrigan/Common-PowerShell/.github/workflows/ci-powershell.yml@master
```

The shared workflow runs `scripts\Run-Tests.ps1` on PowerShell 7.
No additional CI configuration is needed in this repo.

Three more thin workflows lint the non-PowerShell surfaces by delegating to
shared reusable workflows, so the lint config is single-sourced and cannot
drift per repo. The YAML and Bash gates come from **Common-Automation**; the
Ansible gate comes from **Common-Ansible**, which pins the ansible-lint
toolchain next to the controller venv this repo already consumes:

| Workflow | Runs |
|---|---|
| `.github/workflows/ci-yaml.yml` | actionlint, action-validator, yamllint |
| `.github/workflows/ci-bash.yml` | shellcheck, check-sh-executable, bats |
| `.github/workflows/ci-ansible.yml` | ansible-lint (from Common-Ansible) |

Each linter auto-skips when its surface is absent. To reproduce the same checks
locally (Git Bash + Docker), three sibling shim commands map to the CI surface:

```bash
# MAIN entry: the full local equivalent of ci-yaml.yml + ci-bash.yml -
# runs the whole lint suite AND the bats tests in one go.
scripts/run-ci-yaml-and-bash.sh              # or double-click scripts\run-ci-yaml-and-bash.bat

# Run a single half - lint only (shellcheck, actionlint, action-validator,
# yamllint, ansible-lint). No PowerShell tests; distinct from Run-Tests.ps1.
scripts/run-lint-yaml-and-bash.sh            # or double-click scripts\run-lint-yaml-and-bash.bat

# Run a single half - the bats tests only.
scripts/run-tests-bash.sh                    # or double-click scripts\run-tests-bash.bat

# Re-stage the +x bit on tracked *.sh files (Windows checkouts drop it,
# tripping the check-sh-executable gate).
scripts/fix-permissions.sh     # or scripts\fix-permissions.bat
```

All three are thin shims over Common-Automation's engine, pointed at this repo
via `COMMON_AUTOMATION_TARGET_REPO`, so a sibling checkout at
`..\Common-Automation` is required. `.gitattributes` pins `*.sh` to LF and
`*.bat` to CRLF - Linux CI runners reject CRLF shebangs.

---

## Repo structure

This repo carries **two user-provisioning implementations** plus the secret
store they share, organised as self-contained slices under `hyper-v/ubuntu/`.
Each slice holds its own code **and** tests:

| Bucket | Slice |
|---|---|
| **Shared** | `hyper-v/ubuntu/shared/` — `setup-secrets.ps1` (writes the vault both impls read) + module deps |
| **PowerShell impl** | `hyper-v/ubuntu/PowerShell/` — entry points + `reconcile/` logic |
| **Ansible impl** (Common-Ansible consumer) | `hyper-v/ubuntu/Ansible/` — roles, playbooks, ops wrappers, requirements |
| **Tooling** | `.github/`, `scripts/`, `ansible.cfg` (lint shim, see below), `.gitattributes`, `docs/` |

```
hyper-v/ubuntu/
  shared/                       Used by both impls
    setup-secrets.ps1             One-time vault setup
    Install-ModuleDependencies.ps1
    Tests/                        setup-secrets.Tests.ps1
  PowerShell/                   PowerShell user implementation
    create-users.ps1              Thin entry - calls the orchestrator (create direction)
    remove-users.ps1              Thin entry - calls the orchestrator (remove direction)
    reconcile/
      common/                       Shared orchestrator (Invoke-VmUserReconcileRun), config parser, declared-groups guard
      up/                           Create-direction reconcile helpers
      down/                         Remove-direction reconcile helpers
    Tests/
      reconcile/ {common,up,down}     Unit tests mirroring the impl
      Integration.DockerHost/         One shared SSH session (Docker)
      create-users.Tests.ps1  remove-users.Tests.ps1
  Ansible/                      Ansible user implementation (Common-Ansible consumer)
    ops/                          Operator wrappers + domain helpers
      create-users.sh / .bat  remove-users.sh / .bat   Flow entries (dispatch the substrate bridge)
      bootstrap-controller.sh / .bat   Reuse the Common-Ansible controller venv
      _build-extra-vars-VmUsers.sh     User-domain extra-vars fragment (emits vm_users_config)
      imports/_common-ansible-root.sh  Resolves the Common-Ansible sibling root
    playbooks/                    create-users.yml, remove-users.yml, smoke.yml + tasks/
    roles/                        vm_users_entry, groups, users, sudoers
    requirements.yml              Galaxy collections (molecule + bootstrap)
    Tests/
      molecule/ {groups,users,sudoers}   default + remove scenarios per role
ansible.cfg                     Lint shim: keeps the fleet ansible-lint gate active for the
                                nested Ansible slice (roles_path -> hyper-v/ubuntu/Ansible/roles).
                                NOT used at runtime - the bridge uses the substrate's ansible.cfg.
.github/workflows/
  ci.yml                        Delegates to shared ci-powershell.yml in Common-PowerShell
  ci-yaml.yml  ci-bash.yml      Delegate to Common-Automation reusable workflows
scripts/
  Run-Tests.ps1  Run-IntegrationTests.ps1   Pester unit / integration runners
  run-ci-yaml-and-bash.sh / .bat            MAIN: full local lint + bats
  run-lint-yaml-and-bash.sh / .bat          Lint half only (cross-cutting linters + ansible-lint)
  run-lint-ansible.sh                       ansible-lint via the shared Common-Ansible controller venv
  run-tests-bash.sh / .bat                  Bats test half only
  fix-permissions.sh / .bat                 Re-stage +x on tracked *.sh
docs/dev/                       playbook-conventions.md + implementation/
.gitattributes                  Pins *.sh to LF and *.bat to CRLF
```

[Common-Ansible]: ../Common-Ansible
[Infrastructure-E2E]: ../Infrastructure-E2E
[Infrastructure-Vm-Provisioner]: ../Infrastructure-Vm-Provisioner
