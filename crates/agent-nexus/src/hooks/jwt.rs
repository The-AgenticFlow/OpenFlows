// crates/agent-nexus/src/hooks/jwt.rs
//! HS256 JWT verification for Coder agent lifecycle hook dispatches.
//!
//! Coder signs each hook request with the deployment-wide
//! `CODER_CHAT_HOOK_SECRET` and sends the token in `Authorization: Bearer`.
//! Per the gist/coder contract the consumer must check:
//!   - signature (HS256 against the shared secret),
//!   - `iss`,
//!   - `aud` == the hook URL,
//!   - `exp`,
//!   - `jti` == `dispatch_id`,
//!   - `body_sha256` == sha256 of the request body.
//!
//! This is the OpenFlows-side analogue of `codersdk/x/agenthooks`
//! `agenthooks.NewHTTPHandler`.

use anyhow::{anyhow, Context, Result};
use jsonwebtoken::{decode, Algorithm, DecodingKey, Validation};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// The expected issuer Coder uses for hook JWTs.
const EXPECTED_ISSUER: &str = "coder";

/// Claims verified on the hook JWT.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct HookClaims {
    /// Emitted by Coder (expected "coder").
    pub iss: String,
    /// Audience — must equal the configured hook URL.
    pub aud: String,
    /// Expiry (unix seconds).
    pub exp: usize,
    /// JWT ID — must equal the `dispatch_id` in the payload.
    pub jti: String,
    /// Event type — must equal the body `type`.
    #[serde(default)]
    pub r#type: Option<String>,
    /// Subject — must be `coder:chat:<chat_id>`.
    #[serde(default)]
    pub sub: Option<String>,
    /// SHA-256 hex digest of the raw request body.
    pub body_sha256: Option<String>,
}

/// Compute the hex SHA-256 of the raw request body for `body_sha256` checks.
pub fn sha256_hex(body: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(body);
    let digest = hasher.finalize();
    let mut out = String::with_capacity(digest.len() * 2);
    for b in digest {
        out.push_str(&format!("{:02x}", b));
    }
    out
}

/// Verify the `Authorization: Bearer <jwt>` token against the shared secret
/// and bind it to the actual request body + configured hook URL.
///
/// Returns the parsed claims on success.
pub fn verify_hook_jwt(
    auth_header: Option<&str>,
    secret: &str,
    expected_aud: &str,
    dispatch_id: &str,
    chat_id: &str,
    event_type: &str,
    body: &[u8],
) -> Result<HookClaims> {
    let header = auth_header
        .and_then(|h| h.strip_prefix("Bearer "))
        .context("missing Authorization: Bearer header")?;

    let mut validation = Validation::new(Algorithm::HS256);
    validation.set_issuer(&[EXPECTED_ISSUER]);
    validation.set_audience(&[expected_aud]);
    validation.validate_exp = true;

    let key = DecodingKey::from_secret(secret.as_bytes());
    let token = decode::<HookClaims>(header, &key, &validation)
        .map_err(|e| anyhow!("hook JWT verification failed: {e}"))?;

    let claims = token.claims;

    // `jti` must equal the dispatch_id carried in the payload.
    if !claims.jti.is_empty() && claims.jti != dispatch_id {
        return Err(anyhow!(
            "hook JWT jti `{}` does not match payload dispatch_id `{}`",
            claims.jti,
            dispatch_id
        ));
    }

    // `type` (JWT) must equal the body event type.
    if let Some(t) = &claims.r#type {
        if t != event_type {
            return Err(anyhow!(
                "hook JWT type `{}` does not match payload type `{}`",
                t,
                event_type
            ));
        }
    }

    // `sub` must be `coder:chat:<chat_id>`.
    if let Some(sub) = &claims.sub {
        let expected_sub = format!("coder:chat:{chat_id}");
        if sub != &expected_sub {
            return Err(anyhow!(
                "hook JWT sub `{}` does not match payload chat_id `{}`",
                sub,
                chat_id
            ));
        }
    }

    // `body_sha256` must match the actual request body (anti-replay /
    // integrity for rewrites).
    if let Some(claimed) = &claims.body_sha256 {
        let actual = sha256_hex(body);
        if !actual.eq_ignore_ascii_case(claimed) {
            return Err(anyhow!(
                "hook JWT body_sha256 mismatch (got `{}`, expected `{}`)",
                actual,
                claimed
            ));
        }
    }

    Ok(claims)
}
