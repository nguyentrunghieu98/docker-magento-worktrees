# docker-magento-worktrees

Use many Magento 2 Git worktrees with **one** [Mark Shust docker-magento](https://github.com/markshust/docker-magento) stack.

Switch branches by moving a single symlink (`.active-src`) instead of editing Compose files, copying `src/`, or running a second stack. The database, Redis, OpenSearch, RabbitMQ, `vendor/` and `node_modules/` stay shared, so a new worktree is usable within seconds of `git worktree add`.

```
src/                      the main checkout - never moved
.worktrees/<branch>       extra checkouts created by bin/wt
.active-src -> <checkout> what Docker mounts at /var/www/html
```

## Why this exists

The usual "one stack per branch" setup means a second MySQL, a second search engine and another 3 GB of `vendor/` per branch. Symlinking `src/` to a worktree gets you most of the way, but three problems show up:

1. **Docker mounts the symlink target**, not the name, so every switch needs a container recreate - and only the PHP containers need it.
2. **Magento worktrees are incomplete out of the box.** Repositories that keep a whitelist `src/.gitignore` (only `app/code`, `app/design`, `composer.*`, `pub/*`, ...) produce checkouts without `app/bootstrap.php`, `pub/index.php`, `app/etc/env.php` or `nginx.conf`. Nginx then answers 404 even though the code is fine.
3. **Tools create worktrees in different folders** (`~/.codex/worktrees`, `~/Sites/<project>-worktrees`, `src/.worktrees`, ...), so a hand-rolled switcher only knows one convention.

`bin/wt` fixes all three: it recreates only the running PHP services, copies the ignored core files into a new checkout, and resolves worktrees by alias, branch, folder name or absolute path regardless of who created them.

## Requirements

- A docker-magento checkout (`compose.yaml`, `compose.dev.yaml`, `bin/docker-compose`, `bin/magento`).
- The Magento repository cloned into `src/` (`src/.git` must exist).
- Docker Compose v2 (`docker compose version`).
- Bash 4+ and Python 3 only for the installer.

## Install

Clone this repository anywhere, then run its installer from the docker-magento root:

```bash
git clone https://github.com/<you>/docker-magento-worktrees.git ~/docker-magento-worktrees
cd ~/Sites/format                 # your docker-magento root
~/docker-magento-worktrees/install
```

The installer is idempotent and only adds what is missing:

| Change | Why |
| --- | --- |
| copies `bin/wt` | the CLI |
| copies `compose.worktree.yaml` | the Compose overlay that mounts `.active-src` |
| patches `bin/docker-compose` | loads that overlay **after** `compose.dev.yaml`, only when `.active-src` exists |
| adds a `wt:` target to `Makefile` | `make wt use <name>` works like the other targets |
| appends `.active-src` and `.worktrees/` to `.gitignore` | only when the docker root is itself a Git repository |

Then initialize once:

```bash
bin/wt init
bin/wt doctor
```

`init` creates `.worktrees/` and the `.active-src -> src` symlink. `src/` is not touched, so existing worktrees that point their `.git` file at `src/.git/worktrees/<name>` keep working.

Without `init`, `compose.worktree.yaml` is never loaded and the stack behaves exactly as before.

## Quick start

```bash
cd ~/Sites/format

bin/wt init                      # once
bin/wt create feat/toggle-filter # git worktree add .worktrees/feat/toggle-filter + prepare
bin/wt use feat/toggle-filter    # recreate app/phpfpm against that checkout
bin/wt status                    # what is mounted, git state, container state
bin/wt use main                  # back to src/
bin/wt remove feat/toggle-filter # only when inactive and clean; the branch is kept
```

`make wt ...` forwards to `bin/wt`, and `bin/wt` can be called from any directory (it resolves the docker root from its own location).

## Commands

| Command | Description |
| --- | --- |
| `init` | Create `.worktrees/` and `.active-src -> src`. Safe to re-run. |
| `create <branch> [--from REF]` | Add `.worktrees/<branch>`, run `prepare`, print the next step. |
| `list` | Active source plus every worktree Git knows about, with aliases. |
| `use <name\|path\|branch>` | Mount that checkout and recreate the PHP containers. |
| `status` | Active source, path, branch, `git status --short`, `compose ps`. |
| `doctor` | Check the layout, the overlay, the shared folders and `docker compose config`. Exits non-zero on problems. |
| `path <name>` | Print the absolute path, for `cd "$(bin/wt path ...)"`. |
| `prepare <name>` | Create runtime folders and copy the ignored core files a checkout needs. |
| `shell <name>` | Open a host shell inside that checkout. |
| `remove <name>` | Remove an inactive, clean `.worktrees/<name>`; the branch survives. |
| `mounts` | Print the merged `app`/`phpfpm` mounts, i.e. what Docker will really use. |
| `help` | Full usage. |

`use` is also available as `switch`, and `remove` as `rm`.

### `create` base ref

Without `--from`, `create` uses the first ref that exists: local `master`, local `main`, `<remote>/master`, `<remote>/main` for each remote, then `HEAD`. A branch that exists only on a remote is created with `git worktree add --track`.

### `use` behavior

`use` resolves the target, runs `prepare`, stops only the running services among `app`, `phpfpm`, `phpfpm-xdebug`, swaps `.active-src` atomically, recreates those services with `--no-deps --force-recreate`, then runs `bin/magento cache:clean`. If the recreate fails, the symlink is restored and the previous services come back, and the command exits with `Switch canceled`.

Everything else - `db`, `redis`, `opensearch`, `rabbitmq`, `tunnel` - keeps running. Expect one or two seconds in which the storefront can answer 502 while `phpfpm` starts.

## What is shared and what is not

Shared, always read from `src/`:

- MySQL, Redis, OpenSearch, RabbitMQ - one set of containers.
- `vendor/`, `node_modules/` - installed once, reused by every branch.
- `pub/media` - uploads must match the shared database.
- `bin/`, `dev/`, `lib/`, `phpserver/`, `setup/` - Magento framework scripts.
- `conf/php/opcache.ini` - PHP settings.
- `app/etc/env.php` - copied from `src/`, holds the shared DB/Redis credentials.

Per worktree, read from the selected checkout:

- `app/code`, `app/design`, `app/i18n`, `app/etc/config.php`, `app/etc/di.xml`.
- `composer.json`, `composer.lock`, `patches/`.
- `generated/`, `var/`, `pub/static/`, `app/bootstrap.php`, `pub/index.php` and the other core files.
- All Git state, including the checkout's own `.git`.

Consequences worth remembering:

- `composer install` in one branch changes `vendor/` for **every** branch. `bin/wt` warns when `composer.lock` differs, but never blocks.
- A schema change or data patch changes the database for **every** branch. Take a dump before `setup:upgrade`.
- `pub/static` is per worktree, so a fresh branch may need `bin/magento setup:static-content:deploy -f` (or `bin/grunt refresh`).

## Existing worktrees from other tools

`list` shows every worktree Git knows about, and `use` accepts all of them:

| Location | Alias |
| --- | --- |
| `src/` | `main` |
| `.worktrees/<branch>` | `<branch>` |
| `<project>/src/.worktrees/<name>` | `srcwt/<name>` |
| `<project>/.codex-worktrees/<name>` | `local/<name>` |
| anything else, e.g. `~/Sites/<project>-worktrees/<name>`, `~/.codex/worktrees/<name>/src` | `wt/<name>` |

The plain folder name, the branch name and the absolute path work as well. If a name matches several checkouts, the command stops and lists the candidates.

## Testing

The suite is dependency-free and never contacts Docker: it builds a sandbox under `/tmp` with a Git repo, a stub `docker`, and stub `bin/docker-compose` / `bin/magento`.

```bash
bash tests/test-wt.sh
# Summary: 115 checks, 115 passed, 0 failed
```

`MAGENTO_WT_CLI=/path/to/bin/wt` points the suite at a different CLI copy.

The suite covers CLI logic only. Mounts, container recreation and the real content of `/var/www/html` need Docker: `bin/wt doctor` and `bin/wt mounts` after one switch.

## Troubleshooting

**Storefront 404, nginx says the file does not exist**

The checkout is missing Magento core files because `src/.gitignore` whitelists only some paths. Run `bin/wt prepare <name>` (or `bin/wt use <name>` again), then reload. Check `app/bootstrap.php` and `pub/index.php` exist in `bin/wt path <name>`.

**Container still serves `src/` after `use`**

`ls -l .active-src` must point at the wanted checkout. `bin/wt doctor` must print the overlay and wrapper checks as `OK`. `bin/wt mounts` must show `./.active-src` as the `/var/www/html` source, not `./src`. If the overlay is missing, check that `bin/docker-compose` still loads `compose.worktree.yaml` and that `--no-dev` was not passed.

**502 right after `use`**

`phpfpm` is still starting. Wait a few seconds. If it persists, read `docker logs --tail 30 <phpfpm container>` - usually a PHP error in the selected branch, not a mount problem.

**Cron and the cache watcher stop after a switch**

Expected: both run inside `phpfpm`, which is recreated. Restart them from the docker root with `bin/cron start` and `bin/cache-clean --watch`.

**A new worktree is missing from `list`**

`list` reads `git worktree list` of `src/`, so only Git-managed checkouts appear. Create them with `bin/wt create` or `git -C src worktree add <path> <branch>`.

**`remove` refuses**

`Cannot remove the active Docker source` - run `bin/wt use main` first. `Could not remove ...` - the checkout has uncommitted or untracked files; commit, stash or delete them. The branch is always kept.

## Uninstall

```bash
bin/wt use main
rm -f .active-src compose.worktree.yaml bin/wt
mv bin/docker-compose.bak bin/docker-compose   # if the installer created it
```

Remove the `wt:` target from `Makefile` if you want it gone, and the two `.gitignore` entries. Worktrees under `.worktrees/` can be deleted with `git worktree remove`.

## How the overlay works

`compose.dev.yaml` mounts `./src:/var/www/html`. The overlay is passed **after** it, so for the same container target Docker Compose keeps the later declaration:

```yaml
services:
  app:
    volumes:
      - ./.active-src:/var/www/html:cached
  phpfpm:
    volumes:
      - ./.active-src:/var/www/html:cached
```

Docker resolves the symlink when it starts the container, which is why a recreate is needed after a switch - and why only the PHP services need it. The overlay also mounts, from `src/`, the folders that must stay shared (`bin`, `dev`, `lib`, `phpserver`, `setup`, `vendor`, `node_modules`, `pub/media`) plus `conf/php/opcache.ini`.

Only **directories** are mounted inside `/var/www/html` on purpose: Docker creates mount points inside a bind mount, so a bind mount of a single file that does not exist yet would leave a root-owned empty file in the checkout.

## Notes

- One database, one search index, one Redis for every branch: this is one environment that follows the selected source, not parallel sandboxes.
- `.active-src` is machine state, not repository state. Never commit it or copy it to another machine.
- `nginx.conf` comes from `src/nginx.conf.sample` (via `compose.dev.yaml`), so nginx configuration is shared by all worktrees.
- Existing `bin/*` wrappers (`bin/magento`, `bin/cli`, ...) still run from the docker root only; `bin/wt` is the exception because it resolves the root itself.
