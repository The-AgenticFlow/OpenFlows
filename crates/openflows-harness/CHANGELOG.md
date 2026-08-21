# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.0](https://github.com/The-AgenticFlow/openflows/releases/tag/v1.2.0) - 2026-08-21

### Added

- adopt release-plz with develop-as-default branching
- orchestrator Coder agent integration fixes

### Fixed

- move plan storage to Redis SharedStore, replace FORGE polling with NEXUS notification
- *(a2a)* add pair-scope ownership check to tasks/cancel
- *(ci)* resolve failing checks; pin Coder template providers
- *(a2a)* complete verify task transport end-to-end
- *(ci)* resolve failing checks (fmt, clippy, dead-code, unused dep, typo)
- break nexus<->forge_pair infinite loop and fix v2 registry slot derivation

### Other

- Rustfmt
- Address review: SIGTERM→SIGKILL escalation, error sanitization, pair_id ownership checks, idempotency TTL, SSE parsing, request audit, cancel-token sync
- Rustfmt
- sentinel <-> nexus <-> forge
- Task 5.2-5.3: Complete executor sandbox implementation (Refs #143)
- Task 5.1: Implement A2A client for harness (Refs #143)
- Task 3: Add harness verify subcommands CLI skeleton (Refs #143)
- Address review: consume planning gate approval atomically via GETDEL (PR #141)
- Address review: require planning entry and consume gate approval per cycle (PR #141)
- apply rustfmt to openflows-harness crate (PR #141)
- Address review: require SENTINEL role to approve a gate (PR #141)
- Add GitHub token setup and harness improvements for Coder workspaces
- retry CI checks
- fix formatting and trailing whitespace
