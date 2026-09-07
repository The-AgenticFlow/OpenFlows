# OpenFlows → Coder v2.37.0 GA Migration

**Document type:** Migration / source-of-truth record
**Scope:** Migration of OpenFlows' Coder integration from the experimental Chats API to the stable `/api/v2` surface introduced in Coder v2.37.0 (the Coder Agents GA release).
**Status:** Active — migration must land before the experimental compatibility routes are removed in **Coder v2.38**.
**Companion docs:** `openflows-system-architecture.md` (§4 Coder Infrastructure), `openflows-controller.md` (model resolution), `crates/coder-client` (client implementation).

> **Evidence policy.** Every factual claim below is traced to a primary source (coder/coder GitHub releases, PRs, or the official coder.com API reference), cited inline. No claim is asserted on assumption. Any claim that could not be traced is marked **NO PRIMARY SOURCE FOUND**.

---

## 1. The GA release: Coder v2.37.0

Coder promoted **Coder Agents** (including the Chats API) to **Generally Available** in **v2.37.0**, released **01 Sep 2026**.

- Source: https://github.com/coder/coder/releases/tag/v2.37.0 — *"Coder Agents is now generally available: production-ready, commercially supported self-hosted infrastructure for AI coding workflows… This release introduces… a stable Chats API…"*
- Release channel note: v2.37.0 is a **mainline** release; per Coder's release model a mainline becomes **stable** after ~one month. The current GitHub "Latest" *stable* release is **v2.36.4** (also 01 Sep 2026). Sources: https://github.com/coder/coder/releases , https://coder.com/docs/install/releases .

### 1.1 Chats API promoted experimental → `/api/v2`

The Chats API moved from `/api/experimental/chats` to `/api/v2/chats` via **PR #28496** *"feat: mount chat API routes under /api/v2"* (merged 26 Aug 2026), described as *"the base of a 3-PR stack promoting the chat API from `/api/experimental` to `/api/v2`."*

- Sources: https://github.com/coder/coder/pull/28496 ; v2.37.0 release notes (BREAKING CHANGES #1): *"Coder Agents chats API promoted from `/api/experimental` to `/api/v2`."*
- The experimental routes were **retained for a one-month migration window** and are scheduled for **removal in v2.38** (tracked as CODAGT-922). Source: https://github.com/coder/coder/pull/28496 ; v2.37.0 release notes.

### 1.2 Chat-model routes removed immediately

The default-organization chat-model routes were **removed immediately** in v2.37.0 via **PR #28632**: *"The obsolete default-organization chat-model routes `/api/experimental/chats/models` and `/api/experimental/chats/model-configs` are removed immediately in v2.37. Migration: Use `/api/v2/organizations/{organization}/chats/models` instead."*

- Source: https://github.com/coder/coder/releases/tag/v2.37.0 (BREAKING CHANGES #2).

### 1.3 Endpoint mapping

| OpenFlows call (current) | File:line | Experimental path | GA path (v2.37+) |
|---|---|---|---|
| `create_chat` | `crates/coder-client/src/lib.rs:1234` | `POST /api/experimental/chats` | `POST /api/v2/chats` |
| `get_chat` / `get_chat_opt` | `lib.rs:1265` / `1292` | `GET /api/experimental/chats/{id}` | `GET /api/v2/chats/{id}` |
| `list_chats` | `lib.rs:1313` | `GET /api/experimental/chats` | `GET /api/v2/chats` |
| `send_chat_message` | `lib.rs:1347` | `POST /api/experimental/chats/{id}/messages` | `POST /api/v2/chats/{id}/messages` |
| `get_chat_messages` | `lib.rs:1378` | `GET /api/experimental/chats/{id}/messages` | `GET /api/v2/chats/{id}/messages` |
| `archive_chat` | `lib.rs:1411` | `PATCH /api/experimental/chats/{id}` | `PATCH /api/v2/chats/{id}` |
| `interrupt_chat` | `lib.rs:1434` | `POST /api/experimental/chats/{id}/interrupt` | `POST /api/v2/chats/{id}/interrupt` |
| `ChatStream::connect` | `chat_stream.rs:107/112` | `GET /api/experimental/chats/{id}/events` (WS) | `GET /api/v2/chats/{id}/events` (WS) |
| `list_chat_models` | `lib.rs:1468` / `1494` | `GET /api/experimental/chats/models` | `GET /api/v2/organizations/{organization}/chats/models` |

> **OpenFlows state today:** every one of the above calls in `crates/coder-client` still targets the experimental paths. The **models** endpoint (`lib.rs:1468`) is already broken against v2.37; the remaining chat endpoints break when v2.38 ships.

### 1.4 Other v2.37.0 breaking changes that may affect OpenFlows

All from the v2.37.0 BREAKING CHANGES section (https://github.com/coder/coder/releases/tag/v2.37.0). Each needs a verified **no-op-or-follow-up** verdict during migration (see ticket T5):

1. **Agent external auth resolves by template, not config order** — PR #27854. Hostname-only external-auth requests now resolve from the template's declared `coder_external_auth`. Affects workspace templates' Terraform config.
2. **OAuth scopes rejected** — PR #28178. OAuth authorization rejects `openid`/`profile`/`email` with `invalid_scope`. Affects GitHub OAuth sign-in flow.
3. **Dynamic client registration disabled by default** — PR #27316. `POST /oauth2/register` gated behind `oauth2_dcr_enabled` (default off).
4. **Model configs/overrides org-scoped** — PRs #27955/#27959/#28440/#28442/#28704. Existing model configs assigned to default org; deployment/personal overrides not migrated.
5. **MCP server config org-scoped** — PR #27942. Existing configs move to default org; consumers must migrate from deployment-scoped experimental routes to org-scoped routes.
6. **`MinimumImplicitMember` experiment promoted to GA** — PR #27472.
7. **Native chat spend limits removed** — PR #27329; replaced by AI Gateway budgets (limits not migrated).

---

## 2. Deadlines

| Date | Event |
|---|---|
| **01 Sep 2026** | v2.37.0 released; `/api/experimental/chats/models` + `/model-configs` **removed**; Coder Agents GA |
| **~early Oct 2026** (one month after v2.37) | Experimental chats compatibility routes **removed in v2.38**; `:latest` then has no experimental chat surface at all |

Because OpenFlows' `docker-compose.yml:29` runs `ghcr.io/coder/coder:${CODER_IMAGE_TAG:-latest}`, `:latest` already resolves to v2.37.0 today — meaning the **models endpoint is failing now**, and all chat endpoints fail when v2.38 ships.

---

## 3. Version-pinning gap

`openflows-system-architecture.md` §4 (line 450) states *"a verified Coder version is pinned (see §4)"*, but **no Coder version is actually pinned anywhere**:

- `docker-compose.yml:29` → `image: ghcr.io/coder/coder:${CODER_IMAGE_TAG:-latest}` (defaults to `latest`, no pinned default).
- `binary/src/doctor.rs:46` → `CODER_IMAGE_TAG` defaults to `"latest"`.

This is a pre-existing drift between the documented guarantee and the shipped config, and it makes the GA migration urgent rather than optional.

---

## 4. OpenFlows migration workstream (tickets)

Published against **The-AgenticFlow/openflows**. Blocking edges defined in each ticket.

- **Epic:** Migrate OpenFlows to Coder v2.37.0 GA (Chats API experimental → `/api/v2`, org-scoped models, pin version)
- **T1 [URGENT]** Migrate `coder-client` Chats API to `/api/v2` (chat lifecycle + events + org-scoped models endpoint). *No blockers.*
- **T2** Update mock chat server + `coder-client` tests to v2 paths. *Blocked by T1.*
- **T3** Update non-code references (`config/registry.rs`, `types.rs`, `doctor.rs`, docs). *Blocked by T1.*
- **T4** Pin and validate the Coder version (replace `:latest`; document tested version in §4). *Blocked by T1.*
- **T5** Assess the remaining v2.37.0 breaking changes (MCP / model-config / external-auth / OAuth). *No blockers.*
- **T6** Full integration verification against pinned Coder v2.37.0. *Blocked by T1–T5.*

---

## 5. Primary sources

1. https://github.com/coder/coder/releases/tag/v2.37.0 — GA release notes + BREAKING CHANGES (PRs #28496, #28632, #27854, #28178, #27316, #27955, #27942, #27472, #27329)
2. https://github.com/coder/coder/pull/28496 — Chats API `/api/experimental` → `/api/v2` promotion; migration window; CODAGT-921/922
3. https://github.com/coder/coder/releases — release list, dates, "Latest"/"Stable" badges
4. https://coder.com/docs/reference/api/chats — stable `/api/v2/chats` API reference
5. https://coder.com/docs/install/releases — release-channel model (mainline / stable / ESR)
6. https://coder.com/docs/install/docker — recommended self-host image tag `ghcr.io/coder/coder:latest`
7. https://raw.githubusercontent.com/coder/coder/release/2.37/compose.yaml — official compose image tag pattern
