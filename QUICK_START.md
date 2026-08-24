# OpenFlows — Quick Start

This guide covers everything you need to get OpenFlows running on a fresh machine: prerequisites, one-time setup (`.env`, Docker, bootstrap, licenses, tokens), adding a tenant, running the controller, verifying it works, and common troubleshooting.

> **Overview:** For what OpenFlows is, its architecture, how far it has come, and what's left to finish, see the [README](README.md).
>
> **Working directory:** Unless stated otherwise, all commands are run from the **project root** (the directory containing `docker-compose.yml`). There is no need to `cd` into subdirectories.

---

## Prerequisites

- **Docker 24+** — runs Redis, the Coder database, and Coder itself.
- **Rust 1.70+** — builds the `openflows` and `openflows-harness` binaries during bootstrap.
- **Node 18+** — for the GitHub MCP tooling used by agents.
- **The `coder` CLI** on your `PATH` — `prod.sh bootstrap` shells out to `coder templates push`. Install it if missing:
  ```bash
  curl -fsSL https://coder.com/install.sh | sh
  ```
  Then make sure `coder` is on your `PATH` (re-login or add `~/.local/bin` / `~/bin`) and confirm with `coder version`.
- **A GitHub personal access token** with the `repo` scope.

---

## Step 1 — Configure the environment

Run this from the **project root** to create your local `.env`:

```bash
cp .env.example .env
```

Open `.env` and fill in the required variables. The file is well-commented; the table below summarizes every variable so you know what to set and why.

| Variable | Required | Description |
|----------|----------|-------------|
| `GITHUB_TOKEN` | **Yes** | GitHub PAT with the `repo` scope — used to sync issues and create PRs. Get it at <https://github.com/settings/tokens> (classic token, `repo` scope). |
| `GITHUB_REPOSITORY` | **Yes** | Your repo as `owner/repo` (e.g. `my-org/my-repo`). The controller watches this repo for new issues. |
| `CODER_SESSION_TOKEN` | **Yes** | Your personal API token from Coder (the identity OpenFlows runs as — see [Step 4](#step-4--sign-in-add-a-coder-license--get-the-api-token)). Leave empty in Step 1 — you will paste it in Step 4. |

The following variables are optional — the system uses defaults that work out of the box with `docker compose up -d`. Only set them if you host Redis or Coder elsewhere, or want to customize the admin account:

| Variable | Default | Description |
|----------|---------|-------------|
| `REDIS_URL` | `redis://localhost:6379` | Connection URL for Redis. |
| `CODER_URL` | `http://localhost:7080` | HTTP URL of the Coder server. |
| `CODER_ADMIN_USERNAME` | `admin` | Admin username created by bootstrap. |
| `CODER_ADMIN_EMAIL` | `admin@openflows.dev` | Admin email created by bootstrap. |
| `CODER_ADMIN_PASSWORD` | `Op3nFl0ws!` | Admin password created by bootstrap. Must be ≥8 chars with uppercase, lowercase, digit, and special character — otherwise bootstrap silently falls back to the default. |
| `OPENFLOWS_TENANT` | `default` | Namespace prefix for Redis keys. |

> **`.dev-binaries` note:** This directory is created and populated automatically during bootstrap and is bind-mounted into Coder workspaces. If bootstrap fails with `cp: ...: Permission denied`, the directory has become `root`-owned. Fix it:
> ```bash
> sudo chown -R "$USER":"$USER" .dev-binaries/
> ```
> (Create it first if needed: `mkdir -p .dev-binaries`.)

---

## Step 2 — Start the Docker infrastructure

Run this from the **project root** to bring up Redis, the Coder database, and the Coder server:

```bash
docker compose up -d
```

**What this does:** Starts three containerized services (defined in `docker-compose.yml`) that the controller depends on at runtime:

- **Redis** — the shared state store used by the controller to track tickets, worker assignments, and gate approvals (port `6379`).
- **coder-db** — PostgreSQL database that stores Coder's configuration and users (no external port).
- **coder** — the Coder server that provisions and manages workspaces for the AI agents (port `7080`).

Wait until all services are healthy:

```bash
docker compose ps
```

You should see `redis`, `coder-db`, and `coder` all reporting `healthy` (or `running`). The `coder` service runs a healthcheck, so give it a few seconds on first start.

> **Port 6379 conflict:** If the container fails with `failed to bind host port 0.0.0.0:6379/tcp: address already in use`, another process or container is already bound to port 6379 (e.g. a `streamr-redis` container). Remove or stop the conflicting container, or change the port mapping in `docker-compose.yml`.

---

## Step 3 — Bootstrap (one-time setup)

Run this from the **project root** to initialize Coder with the templates and configuration OpenFlows needs:

```bash
./scripts/prod.sh bootstrap
```

**What this does and why each step matters:**

1. **Build and sync dev binaries** — compiles the `openflows` controller and `openflows-harness` worker binary in release mode, then copies both to `.dev-binaries/`. This directory is mounted into Coder workspaces so they have the latest version of the tools.
2. **Create the admin user in Coder** — creates the initial admin account using the credentials from `.env` (see Step 4 for defaults).
3. **Push workspace templates** — deploys the `nexus`, `forge`, `sentinel`, `vessel`, and `lore` templates to Coder. These templates define the workspaces that each AI agent will run in.
4. **Verify LLM/GitHub auth** — checks that a GitHub token is present and that at least one LLM model is configured in Coder's AI settings.

---

## Step 4 — Sign in, add a Coder license & get the API token

The bootstrap script creates the initial Coder admin account. By default the credentials are:

| Field | Default |
|-------|---------|
| Username | `admin` |
| Email | `admin@openflows.dev` |
| Password | `Op3nFl0ws!` |

Override them with `CODER_ADMIN_USERNAME` / `CODER_ADMIN_EMAIL` / `CODER_ADMIN_PASSWORD` in `.env` before running bootstrap.

> **Password requirements:** If the `CODER_ADMIN_PASSWORD` you set does not meet Coder's security requirements (at least 8 characters, and containing an uppercase letter, a lowercase letter, a digit, and a special character), bootstrap **silently falls back to `Op3nFl0ws!`** and creates the admin with that instead. Either set a password that satisfies these requirements, or sign in with the default `Op3nFl0ws!` (check the bootstrap output for the "falling back to default" warning).

Then:

1. Open **http://localhost:7080**
2. **Sign in with the admin credentials above** (first-time only). GitHub sign-up is enabled by default — team members can sign in with their GitHub accounts via Coder's device flow.
3. **Add a Coder license** — create a license from your account at coder.com, then add it at **[http://localhost:7080/deployment/licenses/add](http://localhost:7080/deployment/licenses/add)**. Coder requires a valid license before some functionality is enabled. For local development you can use Coder's free/developer license — see <https://coder.com/docs/next/admin/licenses>.
4. **Configure an LLM model** — OpenFlows agents need at least one model configured. Go to **[http://localhost:7080/ai-settings/agents](http://localhost:7080/ai-settings/agents)** → click the **Models** tab and add a provider/model (e.g. OpenAI, Anthropic).
5. Click your **username** (top-right corner) → **Account** → **Tokens** (or go directly to **[http://localhost:7080/settings/tokens](http://localhost:7080/settings/tokens)**).
6. Click **Create Token**, copy the token, and paste it into `.env` as:
   ```bash
   CODER_SESSION_TOKEN=your_token_here
   ```

### Step 4a — Grant your (non-admin) user the permissions OpenFlows needs

OpenFlows is **self-provisioned**: the user who owns `CODER_SESSION_TOKEN` is the identity OpenFlows runs as. When you sign in with GitHub OAuth, Coder creates you as a **regular member**. A regular member can *access* templates but **cannot create workspaces or push templates** — the two things bootstrap does (push the `openflows-*` templates and create the `openflows-nexus` control-plane workspace under your own user).

> **No `owner` role needed.** You do not need Coder's deployment `owner` role, and OpenFlows no longer creates a separate per-tenant Coder user. You only grant *your own user* the org-level permissions to manage templates and create your own workspace.

**Roles OpenFlows needs:**

| Role | Why |
|------|-----|
| `organization-admin` | Grants `workspace:create` (create the `openflows-nexus` control-plane workspace) and template management in the org. |
| `organization-template-admin` | Grants template management (push/update the `openflows-*` templates). |
| `organization-workspace-access` | OAuth users get this by default; it grants access to org workspaces and is required to create/build the `openflows-nexus` workspace. Keep it — `edit-roles` replaces the whole role set. |

> **⚠️ Important — the `organization-workspace-creation-ban` trap:** This role carries a *negative* `workspace:create` permission that **overrides** `organization-admin`. A user who is org-admin but also has this role still gets `403 Unauthorized to create workspace`. If you see that error, check that this role is **not** assigned.

**Via CLI:**

> **Note:** `edit-roles` **replaces** the user's entire organization-role set rather than appending to it. In particular, a GitHub OAuth user already has `organization-workspace-access` — dropping it removes their ability to create and use org workspaces, so bootstrap would still fail with `403 Unauthorized to create workspace`. Include ALL existing roles (custom, Coder Agents, and `organization-workspace-access`) on this command, or they'll be removed.

```bash
export CODER_URL=http://localhost:7080
export CODER_SESSION_TOKEN=<your-token>

# List your organizations (note the org name, e.g. "coder")
coder organizations list

# Grant the roles (replace <org> and <username>; include ANY existing roles as well, e.g. organization-workspace-access)
coder organizations members edit-roles -O=<org> <username> \
  organization-admin \
  organization-template-admin \
  organization-workspace-access

# Verify the user's roles
coder organizations members list -O=<org>
```

**Via the dashboard:**
1. Open **http://localhost:7080**
2. Go to **Admin settings → Organizations → `<your org>` → Members**
3. Find the user, click **Edit roles**, and select `organization-admin` and `organization-template-admin`. Keep `organization-workspace-access` selected as well.
4. Confirm `organization-workspace-creation-ban` is **not** selected.

Then set that user's token in `.env` as `CODER_SESSION_TOKEN` and re-run `./scripts/prod.sh bootstrap` — OpenFlows will run as that user's own identity. The same token is used when you add a tenant (Step 5), so a tenant is provisioned under your user without Coder's `owner` role.

---

## Step 5 — Add a tenant

Run this from the **project root** to bind a GitHub repository to the controller:

```bash
./scripts/prod.sh tenant <owner/repo> --name <my-team>
```

**What this does:** Registers a team as a tenant so the controller can sync issues from the given repo, provision workspaces, and coordinate agents for that team. The tenant is provisioned under your own authenticated user (from `CODER_SESSION_TOKEN`) — OpenFlows does **not** create a separate Coder user for the tenant, so no `owner`/admin role is needed. You must add at least one tenant before starting the controller. See [TOKEN_GUIDE.md](TOKEN_GUIDE.md) for the token acquisition walkthrough.

---

## Step 6 — Run the controller

Run this from the **project root** (open a **separate terminal** — the controller runs in the foreground and streams logs to that terminal):

```bash
./scripts/prod.sh run
```

**What this does and why:** The controller is the brain of OpenFlows. It syncs open GitHub issues as tickets, assigns them to available forge workers, provisions Coder workspaces for those workers, and coordinates the agent team through the full issue-to-PR lifecycle.

This command **always** resets Redis to a clean slate first (removing any stale tickets, workers, and gate records from previous runs), then starts the controller in the foreground.

Create a GitHub issue in a bound repo → OpenFlows automatically assigns, provisions a workspace, and starts working.

---

## Step 7 — Verify it's working

Because the controller runs in the foreground, its logs stream directly to the terminal where you started `./scripts/prod.sh run`. In a **separate terminal** (also from the project root) you can verify:

```bash
# Health check
./scripts/prod.sh doctor
```

Confirm the Docker services are healthy:

```bash
docker compose ps
```

A successful health check shows Coder and Redis healthy. Verify the controller separately by confirming that its foreground terminal remains running and streams sync/provisioning activity after you create an issue.

> **On `/tmp/openflows-controller.log`:** That log file only exists in the **production** flow, where the controller runs inside a Nexus workspace and its startup script redirects output (`openflows run >/tmp/openflows-controller.log`). Locally, `prod.sh run` runs in the foreground — watch that terminal instead.

---

## Troubleshooting

### `Failed to run coder templates push` (during bootstrap)

The `coder` CLI is missing or not on your `PATH`. Bootstrap shells out to `coder templates push`. Install it:

```bash
curl -fsSL https://coder.com/install.sh | sh
```

Ensure `coder` is on your `PATH`, confirm with `coder version`, then re-run bootstrap.

### `CODER_URL not set` / `Error: Failed to create bootstrapper from environment` (during bootstrap)

The CLI defaults to `http://localhost:7080` when `CODER_URL` is not set, so the old bootstrap error should no longer appear. If you still see a connection failure, check that `CODER_URL` in `.env` is not set to an empty or malformed value — an empty value (`CODER_URL=`) is treated as the URL itself rather than falling back to the default. If you do need a different URL, set it to a valid value:

```bash
CODER_URL=http://your-coder-host:7080
```

### `REDIS_URL is not set` (during `prod.sh run`)

The CLI defaults to `redis://localhost:6379` when `REDIS_URL` is not set, so the old run error should no longer appear. If you still see a connection failure, check that `REDIS_URL` in `.env` is not set to an empty or malformed value — an empty value (`REDIS_URL=`) is treated as the URL itself rather than falling back to the default. If you do need a different URL, set it to a valid value:

```bash
REDIS_URL=redis://your-redis-host:6379
```

### "No LLM models configured in Coder"

Open the Coder dashboard → **[http://localhost:7080/ai-settings/agents](http://localhost:7080/ai-settings/agents)** → click the **Models** tab and configure at least one provider/model, then re-run bootstrap.

### `cp: cannot create regular file '.dev-binaries/openflows': Permission denied`

The `.dev-binaries/` directory is `root`-owned. Take ownership:

```bash
sudo chown -R "$USER":"$USER" .dev-binaries/
```

### Missing required environment variables

Make sure `.env` is in the project root:

```bash
cp .env.example .env
# Edit .env with your tokens
```

### Redis container not responding

```bash
docker ps | grep redis
docker compose up -d   # restart if needed
```

### `failed to bind host port 0.0.0.0:6379/tcp: address already in use`

Another process or container already holds port 6379. Find the conflicting container with `docker ps --format '{{.Names}}\t{{.Ports}}' | grep 6379` and remove/stop it (e.g. `docker rm -f streamr-redis`), or change the redis port mapping in `docker-compose.yml`.

### Controller not picking up issues

1. Confirm a tenant is bound (`./scripts/prod.sh tenant <owner/repo> --name <my-team>`).
2. Check the terminal running the controller for errors (locally) — or `tail -f /tmp/openflows-controller.log` in the production flow.
3. Verify Coder is reachable: `curl http://localhost:7080/api/v2/buildinfo`.

---

## For More Details

- **Full Documentation**: See [README.md](README.md)
- **Testing & Debugging**: See [TESTING_QUICK_START.md](TESTING_QUICK_START.md)
- **Token Acquisition**: See [TOKEN_GUIDE.md](TOKEN_GUIDE.md)
