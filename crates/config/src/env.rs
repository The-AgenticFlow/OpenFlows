//! Centralized environment configuration.
//!
//! All process-startup configuration is defined here as [`envconfig`] -derived
//! structs so that env-var reads are type-safe, validated, and initialized once
//! at startup instead of being scattered as inline `std::env::var(...)` calls
//! across the workspace.
//!
//! The structs intentionally use conservative defaults so existing deployments
//! keep working, while required values (e.g. Coder auth tokens in the
//! controller) surface clear errors at startup.

use envconfig::Envconfig;
use std::path::PathBuf;

/// Coder-related configuration.
#[derive(Debug, Clone, Envconfig)]
pub struct CoderConfig {
    #[envconfig(from = "CODER_URL", default = "http://localhost:7080")]
    pub url: String,

    #[envconfig(from = "CODER_SESSION_TOKEN")]
    pub session_token: Option<String>,

    #[envconfig(from = "CODER_ADMIN_EMAIL", default = "admin@openflows.dev")]
    pub admin_email: String,

    #[envconfig(from = "CODER_ADMIN_PASSWORD", default = "Op3nFl0ws!")]
    pub admin_password: String,

    #[envconfig(from = "CODER_IMAGE_TAG", default = "latest")]
    pub image_tag: String,

    #[envconfig(from = "CODER_GITHUB_TOKEN")]
    pub github_token: Option<String>,

    #[envconfig(from = "CODER_EXTERNAL_AUTH_0_ID")]
    pub external_auth_id: Option<String>,

    #[envconfig(from = "CODER_EXTERNAL_AUTH_0_SECRET")]
    pub external_auth_secret: Option<String>,
}

impl CoderConfig {
    /// Resolve the effective Coder auth token (the session token).
    pub fn effective_token(&self) -> Option<String> {
        self.session_token.clone()
    }
}

/// Infrastructure configuration (Redis, A2A relay).
#[derive(Debug, Clone, Envconfig)]
pub struct InfraConfig {
    #[envconfig(from = "REDIS_URL", default = "redis://localhost:6379")]
    pub redis_url: String,

    #[envconfig(from = "A2A_RELAY_ADDR", default = "127.0.0.1:3000")]
    pub a2a_relay_addr: String,
}

/// OpenFlows tenant / namespace configuration.
#[derive(Debug, Clone, Envconfig)]
pub struct TenantConfig {
    #[envconfig(from = "OPENFLOWS_TENANT", default = "default")]
    pub tenant: String,

    #[envconfig(from = "OPENFLOWS_TICKET")]
    pub ticket: Option<String>,

    #[envconfig(from = "OPENFLOWS_ROLE")]
    pub role: Option<String>,

    #[envconfig(from = "OPENFLOWS_HOME")]
    pub home: Option<String>,

    #[envconfig(from = "OPENFLOWS_REGISTRY_PATH")]
    pub registry_path: Option<String>,

    #[envconfig(from = "OPENFLOWS_REGISTRY_JSON")]
    pub registry_json: Option<String>,

    #[envconfig(from = "OPENFLOWS_NEXUS_WORKSPACE_ID")]
    pub nexus_workspace_id: Option<String>,

    #[envconfig(from = "OPENFLOWS_NEXUS_WORKSPACE_NAME")]
    pub nexus_workspace_name: Option<String>,

    #[envconfig(from = "OPENFLOWS_NEXUS_API_TOKEN")]
    pub nexus_api_token: Option<String>,

    #[envconfig(from = "OPENFLOWS_TAR", default = "tar")]
    pub tar: String,
}

impl TenantConfig {
    /// Resolve the OpenFlows home directory, defaulting to `~/.openflows`.
    pub fn openflows_home(&self) -> PathBuf {
        if let Some(home) = &self.home {
            return PathBuf::from(home);
        }
        let base = std::env::var("HOME")
            .or_else(|_| std::env::var("USERPROFILE"))
            .unwrap_or_else(|_| ".".into());
        PathBuf::from(base).join(".openflows")
    }
}

/// GitHub-related configuration.
#[derive(Debug, Clone, Envconfig)]
pub struct GithubConfig {
    #[envconfig(from = "GITHUB_REPOSITORY")]
    pub repository: Option<String>,

    #[envconfig(from = "GITHUB_TOKEN")]
    pub token: Option<String>,

    #[envconfig(from = "GITHUB_PERSONAL_ACCESS_TOKEN")]
    pub personal_access_token: Option<String>,
}

impl GithubConfig {
    /// Effective GitHub token, preferring the personal access token and falling
    /// back to the generic `GITHUB_TOKEN`.
    pub fn effective_token(&self) -> Option<String> {
        self.personal_access_token
            .clone()
            .or_else(|| self.token.clone())
    }
}

/// Agent/workspace configuration.
#[derive(Debug, Clone, Envconfig)]
pub struct AgentConfig {
    #[envconfig(from = "AGENTFLOW_WORKSPACE_ROOT")]
    pub workspace_root: Option<String>,

    #[envconfig(from = "WORKSPACE_ROOT")]
    pub legacy_workspace_root: Option<String>,

    #[envconfig(from = "USE_AI_GATEWAY", default = "false")]
    pub use_ai_gateway: bool,
}

impl AgentConfig {
    /// Resolve the effective workspace root across the two accepted names.
    pub fn effective_workspace_root(&self) -> Option<String> {
        self.workspace_root
            .clone()
            .or_else(|| self.legacy_workspace_root.clone())
    }
}

/// Aggregated environment configuration loaded once at startup.
#[derive(Debug, Clone)]
pub struct EnvConfig {
    pub coder: CoderConfig,
    pub infra: InfraConfig,
    pub tenant: TenantConfig,
    pub github: GithubConfig,
    pub agent: AgentConfig,
}

impl EnvConfig {
    /// Validate the fields required to run the OpenFlows controller (in a
    /// nexus workspace). Returns a clear error naming the first missing value.
    ///
    /// # Errors
    /// Returns an error when a controller-required variable is not set.
    pub fn validate_controller(&self) -> anyhow::Result<()> {
        if self.coder.effective_token().is_none() {
            anyhow::bail!(
                "CODER_SESSION_TOKEN is not set. The Controller must run inside an \
                 openflows-nexus workspace."
            );
        }
        if self.tenant.tenant.is_empty() {
            anyhow::bail!(
                "OPENFLOWS_TENANT is not set. The Controller must run inside an \
                 openflows-nexus workspace."
            );
        }
        if self
            .github
            .repository
            .as_deref()
            .unwrap_or_default()
            .is_empty()
        {
            anyhow::bail!(
                "GITHUB_REPOSITORY is not set. The Controller must run inside an \
                 openflows-nexus workspace."
            );
        }
        Ok(())
    }

    /// Initialize all config structs from the environment, returning a clear
    /// error naming any missing/invalid variable. The caller decides whether to
    /// load a `.env` file first (e.g. via `dotenvy::dotenv()`); this function
    /// reads the already-populated process environment only, which keeps it
    /// deterministic and testable.
    ///
    /// # Errors
    /// Returns an error if any required environment variable is missing or a
    /// supplied value fails to parse.
    pub fn from_env() -> anyhow::Result<Self> {
        let coder =
            CoderConfig::init_from_env().map_err(|e| anyhow::anyhow!("Coder config: {e}"))?;
        let infra =
            InfraConfig::init_from_env().map_err(|e| anyhow::anyhow!("Infra config: {e}"))?;
        let tenant =
            TenantConfig::init_from_env().map_err(|e| anyhow::anyhow!("Tenant config: {e}"))?;
        let github =
            GithubConfig::init_from_env().map_err(|e| anyhow::anyhow!("GitHub config: {e}"))?;
        let agent =
            AgentConfig::init_from_env().map_err(|e| anyhow::anyhow!("Agent config: {e}"))?;

        Ok(Self {
            coder,
            infra,
            tenant,
            github,
            agent,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn clear(keys: &[&str]) {
        for k in keys {
            unsafe {
                std::env::remove_var(k);
            }
        }
    }

    #[test]
    fn defaults_applied_when_unset() {
        let _g = ENV_LOCK.lock().unwrap();
        clear(&[
            "CODER_URL",
            "CODER_ADMIN_EMAIL",
            "CODER_ADMIN_PASSWORD",
            "CODER_IMAGE_TAG",
            "REDIS_URL",
            "A2A_RELAY_ADDR",
            "OPENFLOWS_TENANT",
            "OPENFLOWS_TAR",
            "USE_AI_GATEWAY",
        ]);
        let cfg = EnvConfig::from_env().unwrap();
        assert_eq!(cfg.coder.url, "http://localhost:7080");
        assert_eq!(cfg.coder.admin_email, "admin@openflows.dev");
        assert_eq!(cfg.coder.admin_password, "Op3nFl0ws!");
        assert_eq!(cfg.coder.image_tag, "latest");
        assert_eq!(cfg.infra.redis_url, "redis://localhost:6379");
        assert_eq!(cfg.infra.a2a_relay_addr, "127.0.0.1:3000");
        assert_eq!(cfg.tenant.tenant, "default");
        assert_eq!(cfg.tenant.tar, "tar");
        assert!(!cfg.agent.use_ai_gateway);
    }

    #[test]
    fn overrides_from_env() {
        let _g = ENV_LOCK.lock().unwrap();
        for (k, v) in [
            ("CODER_URL", "http://coder.example.com:8080"),
            ("REDIS_URL", "redis://redis.example.com:6379"),
            ("OPENFLOWS_TENANT", "acme"),
            ("USE_AI_GATEWAY", "true"),
        ] {
            unsafe {
                std::env::set_var(k, v);
            }
        }
        let cfg = EnvConfig::from_env().unwrap();
        assert_eq!(cfg.coder.url, "http://coder.example.com:8080");
        assert_eq!(cfg.infra.redis_url, "redis://redis.example.com:6379");
        assert_eq!(cfg.tenant.tenant, "acme");
        assert!(cfg.agent.use_ai_gateway);
        clear(&[
            "CODER_URL",
            "REDIS_URL",
            "OPENFLOWS_TENANT",
            "USE_AI_GATEWAY",
        ]);
    }

    #[test]
    fn parse_error_for_invalid_bool() {
        let _g = ENV_LOCK.lock().unwrap();
        unsafe {
            std::env::set_var("USE_AI_GATEWAY", "not-a-bool");
        }
        let err = EnvConfig::from_env().unwrap_err();
        assert!(format!("{err}").contains("Agent config"));
        unsafe {
            std::env::remove_var("USE_AI_GATEWAY");
        }
    }

    #[test]
    fn openflows_home_defaults_to_tilde() {
        let _g = ENV_LOCK.lock().unwrap();
        clear(&["OPENFLOWS_HOME", "HOME", "USERPROFILE"]);
        let cfg = EnvConfig::from_env().unwrap();
        assert!(cfg
            .tenant
            .openflows_home()
            .to_string_lossy()
            .ends_with(".openflows"));
    }
}
