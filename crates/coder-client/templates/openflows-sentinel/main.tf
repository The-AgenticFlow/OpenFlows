terraform {
  required_providers {
    coder = { source = "coder/coder" }
    docker = { source = "kreuzwerker/docker" }
  }
}

variable "role" {
  type        = string
  default     = "sentinel"
  description = "Agent role name"
}

variable "ticket_id" {
  type        = string
  default     = ""
  description = "Ticket identifier"
}

variable "redis_url" {
  type    = string
  default = "redis://redis:6379"
}

variable "repo_url" {
  type        = string
  default     = ""
  description = "Git repository URL to clone into the workspace"
}

variable "tenant" {
  type        = string
  default     = ""
  description = "OpenFlows tenant identifier"
}

variable "coder_url" {
  type        = string
  default     = ""
  description = "Coder server URL for API calls"
}

variable "harness_version" {
  type        = string
  default     = "1.1.6"
  description = "openflows-harness binary version to download"
}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
  dir  = "/home/coder/workspace"

  startup_script = <<-EOT
    #!/bin/bash
    set -e

    log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $$*" >&2; }

    # Setup git credentials: get token from workspace owner via Coder API
    # The agent token is injected by Coder as CODER_AGENT_TOKEN env var
    CODER_URL="${var.coder_url}"
    OWNER_ID="${data.coder_workspace_owner.me.id}"
    
    if [ -n "$$CODER_URL" ] && [ -n "$$CODER_AGENT_TOKEN" ] && [ -n "$$OWNER_ID" ]; then
      GITHUB_TOKEN=$(curl -s \
        -H "Coder-Session-Token: $CODER_AGENT_TOKEN" \
        "$CODER_URL/api/v2/users/$OWNER_ID/gitauths/github" 2>/dev/null \
        | jq -r '.access_token // empty')
      
      # Fallback to env var if API call fails
      GITHUB_TOKEN="$${GITHUB_TOKEN:-$$GITHUB_PERSONAL_ACCESS_TOKEN}"
      
      # Configure git with token for HTTPS push auth
      if [ -n "$$GITHUB_TOKEN" ]; then
        git config --global credential.helper store
        echo "https://git:$$GITHUB_TOKEN@github.com" > /home/coder/.git-credentials
        chmod 600 /home/coder/.git-credentials
        log "Configured git credentials for GitHub push auth"
      else
        log "WARNING: No GitHub token available — git push may fail"
      fi
    fi

    # git pull or clone (creds via Coder external auth or configured above)
    if [ -d /home/coder/workspace/.git ]; then
      cd /home/coder/workspace && git pull 2>/dev/null || true
    elif [ -n "${var.repo_url}" ]; then
      git clone ${var.repo_url} /home/coder/workspace 2>/dev/null || true
    fi

    # Download and install openflows-harness (checksum-verified from GitHub release)
    HARNESS_URL="https://github.com/Kilo-Org/openflows/releases/download/v${var.harness_version}/openflows-harness-v${var.harness_version}-x86_64-unknown-linux-musl"
    HARNESS_BIN="/usr/local/bin/openflows-harness"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Downloading openflows-harness v${var.harness_version}..." >&2
    curl -fsSL "$HARNESS_URL" -o "$HARNESS_BIN" && chmod +x "$HARNESS_BIN" || {
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] WARNING: Failed to download openflows-harness — agent will not be able to coordinate" >&2
    }

    # Provision the OpenFlows hook harness for the agent CLI via the shared
    # installer in the orchestration volume (single source of truth for hook
    # wiring across all role templates). Failure is non-fatal.
    ROLE="${var.role}"
    ROLE_BASE="$${ROLE%-*}"   # sentinel-1 -> sentinel
    /home/coder/.openflows/orchestration/plugin/hooks/install.sh "$ROLE" \
      || log "WARNING: hook installation failed — continuing without hooks"

    # Start heartbeat daemon (the ONLY Redis client in the workspace)
    export REDIS_URL="${var.redis_url}"
    export OPENFLOWS_TENANT="${var.tenant}"
    export OPENFLOWS_TICKET="${var.ticket_id}"
    # OPENFLOWS_ROLE must be the BASE role (sentinel), not the worker id
    # (sentinel-1): the controller writes dispatch and reads heartbeats under
    # the base-role key, so a worker-id role would never match.
    export OPENFLOWS_ROLE="$ROLE_BASE"
    export CODER_WORKSPACE_ID="${data.coder_workspace.me.id}"
    nohup openflows-harness heartbeat start >/dev/null 2>&1 &
    log "Heartbeat daemon started (role=$ROLE_BASE ticket=$OPENFLOWS_TICKET)"
  EOT
}

resource "docker_volume" "workspace" {
  name = "openflows-${var.role}-${data.coder_workspace.me.id}"
}

resource "docker_container" "workspace" {
  name  = "openflows-${var.role}-${data.coder_workspace.me.id}"
  image = "codercom/enterprise-base:ubuntu"

  volumes {
    container_path = "/home/coder/workspace"
    volume_name    = docker_volume.workspace.name
  }

  # Mount shared orchestration files (agent definitions, skills, standards, hooks)
  # This volume is created by the Nexus workspace
  volumes {
    container_path = "/home/coder/.openflows/orchestration"
    volume_name    = "openflows-orchestration-${var.tenant}"
    read_only      = true
  }

  env = [
    "REDIS_URL=${var.redis_url}",
    "OPENFLOWS_TENANT=${var.tenant}",
    "OPENFLOWS_TICKET=${var.ticket_id}",
    "OPENFLOWS_ROLE=${var.role}",
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
