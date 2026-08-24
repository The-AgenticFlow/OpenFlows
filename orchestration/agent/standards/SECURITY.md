# Security Guidelines (SECURITY.md)

## 1. Command Approval Gate
All agents must propose "dangerous" bash commands to NEXUS before execution. Dangerous commands include:
- `rm -rf` or any un-scoped deletion.
- `chmod 777` or any permissive permission change.
- `git push --force`.
- `curl | sh` or any external script execution.
- Writing to files outside the assigned worker slot or the `.agent` directory.

## 2. Secrets Management
- NEVER commit API keys or plain text secrets to the repository.
- Use environment variables (`.env`).
- Agents must NOT read `.env` unless explicitly required by their role (e.g., LiteLLM config).
- Known credential directories (e.g., `.claude/`) are automatically excluded from git via `.gitignore` — they must never be pushed to a remote.
- Secrets are automatically detected and redacted from **any** tracked file before any push attempt (see Section 5). This protection is not limited to any specific directory — if a secret appears in a source file, config file, or any other tracked path, the same safeguards apply.

## 3. Input Sanitization
- Sanitize all user-provided strings before using them in shell commands or file paths.
- Prevent shell injection by using array-based process spawning instead of string interpolation where possible.

## 4. Generic Secret Protection (All Files)
The `.claude/` directory is one known source of secrets (it contains provisioned `mcp.json` with `GITHUB_TOKEN`, injected by Coder External Auth), but the protection is fully generic — any file anywhere in the worktree that contains a secret is caught by the same safeguards:

1. **Worktree .gitignore** — Known credential directories (`.claude/`, `.env.local`) are added to each worktree's `.gitignore` during provisioning. Additionally, any directory containing a redacted file is dynamically added to `.gitignore`.
2. **Whole-worktree secret scanning** — `scan_and_scrub_secrets()` recursively scans **all** text files in the worktree for known secret patterns, not just `.claude/`. Any file containing secrets is redacted and its parent directory is added to `.gitignore`.
3. **Safe git add** — `git_add_safe()` runs `untrack_secret_containing_files()` which checks **all** tracked files (`git ls-files`) for secrets and untracks any that contain them, then runs `git add -A`. This catches secrets in any directory.
4. **Generic history rewrite** — Push rejection (GH013) triggers `rewrite_secret_commits()` which identifies all tracked files containing secrets (via `list_secret_containing_tracked_files()`) and removes them from git history via `git filter-branch`. This is not limited to any specific path.
5. **`contains_secrets()` check** — A lightweight check (same patterns, no modification) used to detect whether a file needs untracking or history rewriting.

## 5. Secret Pattern Redaction
The `redact_patterns()` function in `agent-forge` matches and replaces known secret patterns in **any** text file across the worktree:

| Pattern | Redacted to |
|---------|------------|
| `GITHUB_TOKEN": "<value>"` | `GITHUB_TOKEN": "${GITHUB_TOKEN}"` |
| `GITHUB_PERSONAL_ACCESS_TOKEN": "<value>"` | `GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_PERSONAL_ACCESS_TOKEN}"` |
| `ghp_<36 chars>` | `REDACTED_GITHUB_TOKEN` |
| `gho_<36 chars>` | `REDACTED_GITHUB_OAUTH` |
| `ghu_<36 chars>` | `REDACTED_GITHUB_USER` |
| `ghs_<36 chars>` | `REDACTED_GITHUB_SRE` |
| `github_pat_<82 chars>` | `REDACTED_GITHUB_FINE_GRAINED_PAT` |
| `sk-<20 chars>T3<3 chars>` | `REDACTED_OPENAI_KEY` |
| `AKIA<16 chars>` | `REDACTED_AWS_ACCESS_KEY` |

Additionally, the runtime `GITHUB_TOKEN` environment variable value is matched and replaced if found in any file.

## 6. Push Error Feedback Loop
Work is only considered complete when the branch is successfully pushed and a PR is created. The system must not retry blindly:

- Push errors are classified by type (secret scanning rejection, non-fast-forward, generic failure)
- **Secret scanning rejection (GH013):** The system scans the entire worktree for secrets, redacts them, untracks secret-containing files, commits the scrubbed state, rewrites history to remove those files from prior commits, and retries the push. If it still fails, the worker is blocked with the full error detail so NEXUS can make an informed decision.
- **Non-fast-forward rejection:** Only this case triggers `--force-with-lease`. Secret scanning rejections are never force-pushed.
- **Generic rejection:** The worker is blocked immediately with the full stderr in the reason.
- Blocked reasons always include the actual error (e.g., `"Push rejected: secrets detected in git history — GH013: ..."`), not just "needs push/PR creation", preventing infinite blind retry loops.

## 7. File Type Coverage for Secret Scanning
The `scan_and_scrub_secrets()` function scans files with the following extensions and names:

**Extensions:** json, yaml, yml, toml, env, ini, cfg, md, txt, rs, ts, js, py, go, rb, sh, bash, zsh, fish, ps1, bat, xml, html, css, scss, less, tf, tfvars, hcl, properties, conf

**Filenames:** `.env`, `.env.local`, `.env.*`, `credentials`, `secrets`

**Skipped directories:** `.git`, `node_modules`, `target`, `__pycache__`, `.next`, `dist`, `build`

## 8. Known Secret Sources
The `.claude/mcp.json` is one known source (it embeds `GITHUB_TOKEN` for the GitHub MCP server). But the protection is generic — if secrets appear in any other file (e.g., a `.env` accidentally committed, a source file with a hardcoded API key, a Terraform `.tfvars` with credentials), the same scanning, redaction, untracking, and history rewrite applies.

The `McpConfigGenerator` writes the GitHub token directly into `mcp.json` because the GitHub MCP server requires it in the `env` block at startup. This is safe because:
- The `.claude/` directory is gitignored in every worktree (specific known case)
- All text files across the worktree are scanned for secret patterns before any commit
- The shared directory (where SENTINEL's config lives) is also gitignored (`*\n!.gitignore\n`)
- If any file is somehow force-added to git despite .gitignore, the push-time safeguards (Sections 4-6) will catch and remediate the issue before it reaches the remote
