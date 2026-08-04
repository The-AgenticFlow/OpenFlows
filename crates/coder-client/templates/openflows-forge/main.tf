terraform {
  required_providers {
    coder = { source = "coder/coder" }
    docker = { source = "kreuzwerker/docker" }
  }
}

# TEMPORARY: Host path to the .dev-binaries directory on the Docker host.
# Set via TF_VAR_dev_binary_host_path before running `coder templates push`.
# (Remove when switching to GitHub releases for the openflows binaries.)
variable "dev_binary_host_path" {
  description = "Absolute host path to the .dev-binaries directory"
  type        = string
  default     = ""
}

variable "harness_version" {
  type        = string
  default     = "1.1.6"
  description = "openflows-harness binary version to download"
}

# Workspace-level parameters (set per-workspace via Coder API rich_parameter_values)
data "coder_parameter" "role" {
  name        = "role"
  description  = "Agent role name"
  default     = "forge"
  type        = "string"
}

data "coder_parameter" "ticket_id" {
  name        = "ticket_id"
  description  = "Ticket identifier"
  default     = ""
  type        = "string"
}

data "coder_parameter" "redis_url" {
  name        = "redis_url"
  description  = "Redis SharedStore URL"
  default     = "redis://redis:6379"
  type        = "string"
}

data "coder_parameter" "repo_url" {
  name        = "repo_url"
  description  = "Git repository URL to clone into the workspace"
  default     = ""
  type        = "string"
}

data "coder_parameter" "tenant" {
  name        = "tenant"
  description  = "OpenFlows tenant identifier"
  default     = ""
  type        = "string"
}

data "coder_parameter" "coder_url" {
  name        = "coder_url"
  description  = "Coder server URL for API calls"
  default     = ""
  type        = "string"
}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
  dir  = "/home/coder/workspace"

  startup_script = <<-EOT
    #!/bin/bash
    set -e

    log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }

    # TEMPORARY: Use mounted dev binaries for local testing
    # (In production, download from GitHub releases instead)
    HARNESS_BIN="/usr/local/bin/openflows-harness"
    if [ -f /opt/openflows-dev/openflows-harness ]; then
      log "Using mounted dev harness binary..."
      sudo cp /opt/openflows-dev/openflows-harness "$HARNESS_BIN"
      sudo chmod +x "$HARNESS_BIN"
    else
      # Fallback: download from GitHub releases, with retries. The harness is
      # REQUIRED — without it the agent cannot coordinate (dispatch/status/
      # heartbeat), so a missing harness must fail the startup script loudly
      # instead of leaving a silently uncoordinated workspace.
      HARNESS_URL="https://github.com/Kilo-Org/openflows/releases/download/v${var.harness_version}/openflows-harness-v${var.harness_version}-x86_64-unknown-linux-musl"
      log "Downloading openflows-harness v${var.harness_version}..."
      for attempt in 1 2 3; do
        if curl -fsSL --retry 3 "$HARNESS_URL" -o /tmp/openflows-harness; then
          sudo mv /tmp/openflows-harness "$HARNESS_BIN"
          sudo chmod +x "$HARNESS_BIN"
          break
        fi
        log "Harness download attempt $attempt failed; retrying in 5s..."
        sleep 5
      done
    fi
    if [ ! -x "$HARNESS_BIN" ]; then
      log "FATAL: openflows-harness is not installed — agent cannot coordinate; failing startup"
      exit 1
    fi

    # Provision the OpenFlows hook harness for the agent CLI via the shared
    # installer in the orchestration volume (single source of truth for hook
    # wiring across all role templates). Failure is non-fatal.
    ROLE="${data.coder_parameter.role.value}"
    ROLE_BASE="$${ROLE%-*}"   # forge-1 -> forge
    /home/coder/.openflows/orchestration/plugin/hooks/install.sh "$ROLE" \
      || log "WARNING: hook installation failed — continuing without hooks"

    # Setup git credentials: get token from workspace owner via Coder API
    # The agent token is injected by Coder as CODER_AGENT_TOKEN env var
    CODER_URL="${data.coder_parameter.coder_url.value}"
    OWNER_ID="${data.coder_workspace_owner.me.id}"
    
    # Fetch GitHub token via Coder API (uses the agent's own token)
    if [ -n "$CODER_AGENT_TOKEN" ]; then
      GITHUB_TOKEN=$(curl -s \
        -H "Coder-Session-Token: $CODER_AGENT_TOKEN" \
        "$CODER_URL/api/v2/users/$OWNER_ID/gitauths/github" 2>/dev/null \
        | jq -r '.access_token // empty')
    fi
    
    # Fallback to env var if API call fails
    GITHUB_TOKEN="$${GITHUB_TOKEN:-$GITHUB_PERSONAL_ACCESS_TOKEN}"
    
    # Configure git with token for HTTPS push auth
    if [ -n "$GITHUB_TOKEN" ]; then
      git config --global credential.helper store
      echo "https://git:$GITHUB_TOKEN@github.com" > /home/coder/.git-credentials
      chmod 600 /home/coder/.git-credentials
      log "Configured git credentials for GitHub push auth"
    else
      log "WARNING: No GitHub token available — git push may fail"
    fi

    # git pull or clone (creds via Coder external auth or configured above)
    if [ -d /home/coder/workspace/.git ]; then
      cd /home/coder/workspace && git pull 2>/dev/null || true
    elif [ -n "${data.coder_parameter.repo_url.value}" ]; then
      # Clone into a temp dir first, then move contents
      TEMP_DIR=$(mktemp -d)
      if git clone "${data.coder_parameter.repo_url.value}" "$TEMP_DIR" 2>/dev/null; then
        # Move all files (including .git) to workspace
        sudo chown -R coder:coder /home/coder/workspace
        mv "$TEMP_DIR"/* "$TEMP_DIR"/.* /home/coder/workspace/ 2>/dev/null || true
        rmdir "$TEMP_DIR"
      fi
    fi

    # Start heartbeat daemon (the ONLY Redis client in the workspace).
    # OPENFLOWS_ROLE must be the BASE role (forge), not the worker id
    # (forge-1): the controller writes dispatch and reads heartbeats under
    # the base-role key, so a worker-id role would never match.
    export REDIS_URL="${data.coder_parameter.redis_url.value}"
    export OPENFLOWS_TENANT="${data.coder_parameter.tenant.value}"
    export OPENFLOWS_TICKET="${data.coder_parameter.ticket_id.value}"
    export OPENFLOWS_ROLE="$ROLE_BASE"
    export CODER_WORKSPACE_ID="${data.coder_workspace.me.id}"
    nohup openflows-harness heartbeat start >/dev/null 2>&1 &
    log "Heartbeat daemon started (role=$ROLE_BASE ticket=$OPENFLOWS_TICKET)"
  EOT
}

resource "docker_volume" "workspace" {
  name = "openflows-${data.coder_parameter.role.value}-${data.coder_workspace.me.id}"
}

resource "docker_container" "workspace" {
  name  = "openflows-${data.coder_parameter.role.value}-${data.coder_workspace.me.id}"
  image = "codercom/enterprise-base:ubuntu"

  volumes {
    container_path = "/home/coder/workspace"
    volume_name    = docker_volume.workspace.name
  }

  # Mount shared orchestration files (agent definitions, skills, standards)
  # This volume is created by the Nexus workspace
  volumes {
    container_path = "/home/coder/.openflows/orchestration"
    volume_name    = "openflows-orchestration-${data.coder_parameter.tenant.value}"
    read_only      = true
  }

  # TEMPORARY: Mount dev binaries for local testing (remove when using GitHub releases)
  dynamic "volumes" {
    for_each = var.dev_binary_host_path != "" ? [1] : []
    content {
      container_path = "/opt/openflows-dev"
      host_path      = var.dev_binary_host_path
      read_only      = true
    }
  }

  env = [
    "REDIS_URL=${data.coder_parameter.redis_url.value}",
    "OPENFLOWS_TENANT=${data.coder_parameter.tenant.value}",
    "OPENFLOWS_TICKET=${data.coder_parameter.ticket_id.value}",
    # Base role (forge-1 -> forge): harness Redis keys are namespaced by base role
    "OPENFLOWS_ROLE=${replace(data.coder_parameter.role.value, "/-[0-9]+$/", "")}",
    "CODER_WORKSPACE_ID=${data.coder_workspace.me.id}",
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
  ]

  # egress allowlist: Coder control plane + github.com + Redis only
  # (enforced at network level; Redis is a documented exception per docs/governance.md)

  networks_advanced {
    name = "openflows_default"
  }

  entrypoint = ["sh", "-c", replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "coder")]
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}
