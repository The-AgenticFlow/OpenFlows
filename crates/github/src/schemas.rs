// crates/github/src/schemas.rs
//
// Command helper to spawn the GitHub MCP server.
// All tool calls are made through the GitHub REST/MCP interface.

/// Returns the default command to spawn the GitHub MCP server via Docker.
/// The GITHUB_TOKEN env var (from Coder External Auth) is passed to the MCP server.
pub fn github_mcp_cmd() -> Vec<&'static str> {
    vec![
        "docker",
        "run",
        "-i",
        "--rm",
        "-e",
        "GITHUB_TOKEN",
        "ghcr.io/github/github-mcp-server",
    ]
}
