#!/bin/bash
# === OpenFlows Sentinel Session Bootstrap ===
#
# Provides the reviewing agent with everything it needs to avoid "waking up
# blank":
#   1. Workspace environment verification
#   2. Review dispatch payload (what to review: planning gate vs PR review)
#   3. Current gate/review state (resume awareness)
#   4. Exact commands to record the verdict and hand off back to FORGE
#
# All output here becomes the session context for the agent.

set -e

BOLD="\033[1m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
NC="\033[0m"

echo -e "${BOLD}${CYAN}=== OpenFlows Sentinel Session ===${NC}"
echo ""

if [ -z "$OPENFLOWS_TICKET" ] || [ -z "$OPENFLOWS_ROLE" ]; then
    echo -e "${YELLOW}⚠ Environment not fully configured${NC}"
    echo "  OPENFLOWS_TICKET=$OPENFLOWS_TICKET"
    echo "  OPENFLOWS_ROLE=$OPENFLOWS_ROLE"
    echo "  (This is expected if running outside a provisioned workspace.)"
    exit 0
fi

echo -e "${BOLD}Review Assignment:${NC}"
echo "  Ticket: ${CYAN}$OPENFLOWS_TICKET${NC}"
echo "  Role: ${CYAN}${OPENFLOWS_ROLE}${NC}"
echo ""

if ! command -v openflows-harness >/dev/null 2>&1; then
    echo -e "${YELLOW}⚠ openflows-harness not found in PATH${NC}"
    echo "  Coordination with the controller is unavailable."
    exit 0
fi

echo -e "${BOLD}Review Dispatch:${NC}"
if dispatch=$(openflows-harness dispatch read 2>/dev/null); then
    echo "$dispatch" | jq . 2>/dev/null || echo "$dispatch"
else
    echo "  (No dispatch payload yet — controller may still be processing.)"
fi
echo ""

# Show gate status so a resumed session knows whether it already approved.
echo -e "${BOLD}Planning Gate Status:${NC}"
openflows-harness gate status --phase planning 2>/dev/null || echo "  (not approved yet)"
echo ""

echo -e "${BOLD}Your Job:${NC}"
cat <<'EOF'
  The dispatch payload's "review_type" tells you which review to perform:

  planning_gate — FORGE is PAUSED waiting for your plan approval.
    1. Read PLAN.md in the workspace
    2. Evaluate it against the ticket requirements in the dispatch payload
    3. Approve:   openflows-harness gate approve --phase planning --notes "..."
       Reject:    leave specific feedback; do NOT approve the gate
    Approving the gate automatically resumes the paused FORGE worker.

  pr_review — FORGE has opened a PR and is waiting for your verdict.
    1. Read the ticket requirements (dispatch payload) BEFORE the diff
    2. Review the PR: spec match, tests, security, logic
    3. Write your review report to a file (e.g. REVIEW.md), then record it:
         openflows-harness review submit --verdict approve --report REVIEW.md --pr <N>
         openflows-harness review submit --verdict reject  --report REVIEW.md --pr <N>
    The controller routes your verdict: approve → VESSEL merge,
    reject → FORGE resumes with your report as a follow-up message.
EOF
echo ""

echo -e "${BOLD}Harness Commands:${NC}"
cat <<'EOF'
  openflows-harness dispatch read                          # Review assignment payload
  openflows-harness gate approve --phase planning --notes N  # Approve planning gate
  openflows-harness gate status --phase planning           # Check gate state
  openflows-harness review submit --verdict V --report FILE [--pr N]  # Record PR verdict

Policy:
  - All coordination MUST go through the harness (no direct Redis)
  - You are READ-ONLY on the implementation: never edit FORGE's code
  - Do not end the session before recording a verdict or gate decision —
    the paused FORGE worker cannot resume without it
EOF
echo ""

echo -e "${BOLD}${GREEN}Ready to review.${NC} Start with: ${CYAN}openflows-harness dispatch read${NC}"
echo ""
