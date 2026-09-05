# OpenFlows — Quick Start

Get OpenFlows running on a fresh machine in 10 steps. For what OpenFlows is and how it works, see the [README](README.md).

> **Working directory:** all commands run from the **project root** (the directory containing `docker-compose.yml`). No need to `cd` into subdirectories.

## Prerequisites

- Docker 24+
- Rust 1.70+ (builds the `openflows` binary during bootstrap)
- Node 18+
- The `coder` CLI on your `PATH` — bootstrap shells out to `coder templates push`:
  ```bash
  curl -fsSL https://coder.com/install.sh | sh
  ```
- A GitHub personal access token with the `repo` scope.

---

## Step 1 — Start Docker

First, make sure ports 6379 (Redis) and 7080 (Coder) are free so there's no conflict. If you ran OpenFlows before, cleanly stop this project's containers:

```bash
docker compose down
```

If another, unrelated container is already holding one of those ports (e.g. a `streamr-redis` on 6379), find it and remove only that one by name:

```bash
docker ps --filter "publish=6379" --filter "publish=7080"
docker rm -f <conflicting-container-name>
```

Then bring up Redis, the Coder database, and the Coder server:

```bash
docker compose up -d
```

Wait until all three report healthy:

```bash
docker compose ps
```

---

## Step 2 — Set up `.env`

Create your `.env` from the template:

```bash
cp .env.example .env
```

Only these three are required:

| Variable | What to put |
|----------|-------------|
| `GITHUB_TOKEN` | GitHub PAT with `repo` scope. |
| `GITHUB_REPOSITORY` | The repo the controller watches, as `owner/repo`. |
| `CODER_SESSION_TOKEN` | Leave empty for now — you'll fill it in [Step 4](#step-4--get-your-coder-session-token). |

---

## Step 3 — Sign in with GitHub

Open **http://localhost:7080** and sign in with your GitHub account (Coder's device flow).

---

## Step 4 — Get your Coder session token

1. Open **http://localhost:7080/settings/tokens**
2. Click **Create Token**, copy it.
3. Paste it into `.env`:
   ```bash
   CODER_SESSION_TOKEN=your_token_here
   ```

---

## Step 5 — Configure an LLM model

OpenFlows agents need at least one model.

1. Go to **http://localhost:7080/ai/settings/providers**
2. **Add a provider** (e.g. OpenAI, Anthropic).
3. Go to **http://localhost:7080/ai/settings/models** and **add a model** to that provider (e.g. `deepseek-v4-flash-0731`).

---

## Step 6 — Test the AI setup

Open **http://localhost:7080/agents** and confirm agents/models show up. Say "hello" in the chat to verify the model responds.

---

## Step 7 — Bootstrap

Run the one-time setup to initialize Coder with the OpenFlows templates and config:

```bash
./scripts/prod.sh bootstrap
```

This builds the `openflows` binary into `.dev-binaries/`, creates the admin user, pushes the workspace templates, and verifies GitHub/LLM auth.

Confirm the templates were pushed at **http://localhost:7080/templates**.

---

## Step 8 — Add a tenant

Bind a GitHub repo to the controller:

```bash
./scripts/prod.sh tenant <owner/repo> --name <my-team>
```

You'll see the tenant under **http://localhost:7080/workspaces**.

---

## Step 9 — Run the controller

Open a **separate terminal** (the controller runs in the foreground and streams logs) and run:

```bash
./scripts/prod.sh run
```

Create a GitHub issue in the bound repo → OpenFlows automatically assigns it, provisions a workspace, and starts working.

---

## Verify it's working

In a separate terminal:

```bash
./scripts/prod.sh doctor
```

---

## Configuration

These are optional — the defaults work out of the box. Only touch them if you need to.

| Variable | Default | Notes |
|----------|---------|-------|
| `CODER_ADMIN_USERNAME` | `admin` | Admin account created by bootstrap. |
| `CODER_ADMIN_EMAIL` | `admin@openflows.dev` | |
| `CODER_ADMIN_PASSWORD` | `Op3nFl0ws!` | Must be ≥8 chars with upper, lower, digit, and special char — otherwise bootstrap silently falls back to the default. |
| `REDIS_URL` | `redis://localhost:6379` | Set only if you host Redis elsewhere. |
| `CODER_URL` | `http://localhost:7080` | Set only if you host Coder elsewhere. |
| `OPENFLOWS_TENANT` | `default` | Namespace for Redis keys. |
| `SLACK_WEBHOOK_URL` / `DISCORD_WEBHOOK_URL` | unset | Escalation notifications. |

### Granting a non-admin (OAuth) user the needed permissions

When a team member signs in with GitHub OAuth, Coder creates them as a **regular member**, who can't create workspaces or push templates. If you want OpenFlows to run as that user, grant them these roles (or bootstrap fails with `403 Unauthorized to create workspace`):

| Role | Why |
|------|-----|
| `organization-admin` | Create the control-plane workspace + template management. |
| `organization-template-admin` | Push/update the `openflows-*` templates. |
| `organization-workspace-access` | Required for org workspaces. Keep it — `edit-roles` replaces the whole role set. |

> **Trap:** `organization-workspace-creation-ban` carries a *negative* `workspace:create` permission that **overrides** `organization-admin`. If you see `403 Unauthorized to create workspace`, make sure this role is **not** assigned.

Via CLI:

```bash
export CODER_URL=http://localhost:7080
export CODER_SESSION_TOKEN=<your-token>

# List orgs, then grant roles (include ALL existing roles or they'll be removed)
coder organizations list
coder organizations members edit-roles -O=<org> <username> \
  organization-admin \
  organization-template-admin \
  organization-workspace-access
```

Or via the dashboard: **Admin settings → Organizations → `<your org>` → Members → Edit roles** and select the roles above.

---

## Troubleshooting

### `Failed to run coder templates push` (during bootstrap)

`coder` is missing or not on your `PATH`. Install it and re-run bootstrap:

```bash
curl -fsSL https://coder.com/install.sh | sh
coder version
```

### "No LLM models configured in Coder"

Open **http://localhost:7080/ai/settings/providers** and add a provider/model, then re-run bootstrap.

### `cp: cannot create regular file '.dev-binaries/openflows': Permission denied`

The `.dev-binaries/` directory is root-owned:

```bash
sudo chown -R "$USER":"$USER" .dev-binaries/
```

### Port 6379 already in use

Another process/container holds port 6379. Stop or remove the conflicting container, or change the Redis port mapping in `docker-compose.yml`.

### Controller not picking up issues

1. Confirm a tenant is bound (`./scripts/prod.sh tenant <owner/repo> --name <my-team>`).
2. Watch the controller's foreground terminal for errors.
3. Verify Coder is reachable: `curl http://localhost:7080/api/v2/buildinfo`.

---

## More

- **Full docs:** [README.md](README.md)
- **Testing & debugging:** [TESTING_QUICK_START.md](TESTING_QUICK_START.md)
- **Token acquisition:** [TOKEN_GUIDE.md](TOKEN_GUIDE.md)
