# claude-docker

Run Claude Code in an isolated Linux container (Docker Desktop on macOS), one container per project, with all shared plumbing living in this single folder. No Dockerfile — the stock `node:26-slim` image is prepared at launch time by `entrypoint.sh`.

## Layout

```
claude-docker/
├── claude-docker           # launcher — run it from inside any project directory
├── docker-compose.yml
├── entrypoint.sh
├── .env.example            # copy to .env, add your OAuth token
├── claude.json.template    # seeds each new project's container .claude.json
├── state/<project-id>/     # per-project container state (auto-created)
│   ├── claude/             # container ~/.claude (history, sessions, todos)
│   └── claude.json         # container ~/.claude.json (trust, onboarding, MCP)
├── tools/                  # shared npm global prefix; Claude Code lives here
└── apt-cache/              # shared apt archives + lists cache
```

This folder can live anywhere (e.g. `~/claude-docker/`); the launcher resolves its own location, including through symlinks.

## Setup

1. **Token (Claude subscription, macOS).** The host stores its OAuth token in the macOS Keychain, so there is no credentials file to mount. Instead, run once on the host:

   ```sh
   claude setup-token
   ```

   Copy the printed token, then:

   ```sh
   cp .env.example .env
   chmod 600 .env
   # paste the token into .env as CLAUDE_CODE_OAUTH_TOKEN=...
   ```

   The token is passed into containers as an environment variable, shared by all projects, and never baked into any image. The launcher fails with a clear error if it is missing.

2. **Put the launcher on your PATH** (optional but recommended):

   ```sh
   ln -s "$(pwd)/claude-docker" /usr/local/bin/claude-docker
   ```

   or add this folder to `PATH` in your shell profile.

## Usage

From inside any project directory:

```sh
claude-docker            # start Claude Code in a container, cwd mounted at /workspace
claude-docker -c         # extra args are forwarded to claude; -c resumes THIS project's last session
claude-docker --update   # update Claude Code in the shared tools dir (all projects at once)
claude-docker --reset    # delete this project's container state; next launch re-seeds from the template
docker compose -f docker-compose.yml pull   # refresh the node:26-slim base image
```

Claude Code runs with `--dangerously-skip-permissions` inside the container — the container boundary is the sandbox.

## How it works

- **Image without Dockerfile.** The container starts from stock `node:26-slim` as root. `entrypoint.sh` installs the minimal system packages (`git`, `ca-certificates`, plus `EXTRA_APT_PACKAGES` from `.env`), then drops privileges and execs Claude Code as the non-root `node` user. Root is used only for package setup.
- **Fast relaunches.** `apt-cache/` is mounted over apt's archives and lists dirs, so after the first run installs are served from cached `.deb`s and take seconds. Set `SKIP_APT=1` in `.env` for the fastest possible start when git isn't needed. Concurrent launches are safe: apt's own locking plus a retry loop in the entrypoint handle the shared cache.
- **Shared Claude Code install.** `tools/` is the npm global prefix (`NPM_CONFIG_PREFIX`) mounted into every container. If `claude` is missing there, the entrypoint installs it once (a lockfile guards concurrent first runs). `--update` refreshes it for all projects.
- **Per-project state.** The launcher computes a stable project ID from the directory name + a hash of its full path. Each project gets `state/<project-id>/`, mounted read-write as the container's `~/.claude` and `~/.claude.json`. History, sessions, `-c`/`-r` resume, and project trust are fully isolated per project. Deleting one project's state folder resets only that project.
- **Multiple instances.** The project ID is also the compose project name (`-p claude-<project-id>`), so containers and networks never collide across projects. Each invocation is `docker compose run --rm` — an independent, self-cleaning container. Running the same project twice concurrently also works (auto-generated container names); both instances share that project's state folder, which is fine since they belong to the same project.

## Settings shared from the host

Mounted read-only into the container's `~/.claude/` so global instructions and slash commands match the host:

- `~/.claude/CLAUDE.md`
- `~/.claude/settings.json`
- `~/.claude/commands/`
- `~/.claude/agents/`
- `~/.gitconfig` (git identity)

Edits on the host are picked up by the next container launch.

The host's `~/.claude.json` and the rest of `~/.claude` are deliberately **not** mounted: host per-project trust uses macOS paths and Keychain auth, and sharing the full directory between a macOS host and Linux containers can corrupt state.

## claude.json.template

On the **first** launch for a project, its `state/<project-id>/claude.json` is seeded from `claude.json.template`. It ships with the minimal fields to skip onboarding, the bypass-permissions acceptance, and pre-trusted `/workspace`.

To give every **new** project shared user-scope config, edit the template. For example, MCP servers:

```json
{
  "hasCompletedOnboarding": true,
  "bypassPermissionsModeAccepted": true,
  "mcpServers": {
    "deepwiki": {
      "type": "http",
      "url": "https://mcp.deepwiki.com/mcp"
    }
  },
  "projects": { "/workspace": { "hasTrustDialogAccepted": true, "hasCompletedProjectOnboarding": true } }
}
```

An existing project's `claude.json` is **never overwritten** on later runs — template changes apply only to newly seeded projects. To re-seed the current project, run `claude-docker --reset` (deletes that project's state folder; the next launch seeds a fresh copy).

## Isolation guarantees

The container sees only:

- `/workspace` — the project directory you launched from,
- the read-only host config listed above,
- the shared `tools/` and `apt-cache/` folders,
- its own project's `state/` folder.

Nothing else from the host, and nothing from other projects. The container process starts as root only for package setup; Claude Code itself always runs as the non-root `node` user.

## Testing checklist

- [ ] First launch installs git + Claude Code; a second launch (any project) starts in a few seconds using the apt cache and shared tools dir.
- [ ] `SKIP_APT=1` launch starts fastest and Claude Code still works.
- [ ] Launch in project A and project B simultaneously; verify separate containers (`docker ps`) AND separate state folders under `state/`.
- [ ] Kill one instance; the other is unaffected.
- [ ] Restart a container in project A: no re-login, no onboarding, and `-c` resumes project A's session only.
- [ ] Delete project A's state folder and relaunch: it re-seeds from the template, and project B's history is untouched.
- [ ] Add an MCP server to `claude.json.template`: a brand-new project picks it up, existing projects are unchanged.
- [ ] Edit `~/.claude/CLAUDE.md` on the host: new containers see the change.
- [ ] `claude-docker --update` updates Claude Code for all projects at once.
