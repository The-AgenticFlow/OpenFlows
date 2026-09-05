//! Integration tests for the centralized `config::env` layer (issue #185).

use config::{CoderConfig, EnvConfig, InfraConfig, TenantConfig};
use envconfig::Envconfig;
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
fn coder_config_parses_defaults_and_overrides() {
    let _g = ENV_LOCK.lock().unwrap();
    clear(&[
        "CODER_URL",
        "CODER_ADMIN_EMAIL",
        "CODER_ADMIN_PASSWORD",
        "CODER_IMAGE_TAG",
    ]);
    unsafe {
        std::env::set_var("CODER_URL", "http://coder.internal:8080");
    }
    let cfg = CoderConfig::init_from_env().unwrap();
    assert_eq!(cfg.url, "http://coder.internal:8080");
    assert_eq!(cfg.admin_email, "admin@openflows.dev");
    assert_eq!(cfg.admin_password, "Op3nFl0ws!");
    assert_eq!(cfg.image_tag, "latest");
    clear(&[
        "CODER_URL",
        "CODER_ADMIN_EMAIL",
        "CODER_ADMIN_PASSWORD",
        "CODER_IMAGE_TAG",
    ]);
}

#[test]
fn tenant_openflows_home_uses_default() {
    let _g = ENV_LOCK.lock().unwrap();
    clear(&["OPENFLOWS_HOME", "HOME", "USERPROFILE"]);
    let cfg = TenantConfig::init_from_env().unwrap();
    let home = cfg.openflows_home();
    assert!(home.to_string_lossy().ends_with(".openflows"));
}

#[test]
fn infra_defaults_applied() {
    let _g = ENV_LOCK.lock().unwrap();
    clear(&["REDIS_URL", "A2A_RELAY_ADDR"]);
    let cfg = InfraConfig::init_from_env().unwrap();
    assert_eq!(cfg.redis_url, "redis://localhost:6379");
    assert_eq!(cfg.a2a_relay_addr, "127.0.0.1:3000");
}

#[test]
fn env_config_from_env_and_controller_validation() {
    let _g = ENV_LOCK.lock().unwrap();
    clear(&[
        "CODER_SESSION_TOKEN",
        "OPENFLOWS_TENANT",
        "GITHUB_REPOSITORY",
    ]);
    unsafe {
        std::env::set_var("CODER_SESSION_TOKEN", "fake-token");
        std::env::set_var("OPENFLOWS_TENANT", "acme");
        std::env::set_var("GITHUB_REPOSITORY", "acme/repo");
    }
    let env = EnvConfig::from_env().unwrap();
    assert!(env.validate_controller().is_ok());
    clear(&[
        "CODER_SESSION_TOKEN",
        "OPENFLOWS_TENANT",
        "GITHUB_REPOSITORY",
    ]);

    unsafe {
        std::env::set_var("GITHUB_REPOSITORY", "acme/repo");
    }
    let env = EnvConfig::from_env().unwrap();
    assert!(env.validate_controller().is_err());
    clear(&["GITHUB_REPOSITORY"]);
}
