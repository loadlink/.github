#!/usr/bin/env bash
# setup-repo.sh — deploys branch-name-validation workflow to a single org repo.
#
# Called by repo-setup-automation.yml with the following env vars injected:
#   MATRIX_REPO          e.g. "loadlink/my-repo"
#   DRY_RUN              "true" | "false"
#   WORKFLOW_FILE_PATH   e.g. ".github/workflows/branch-name-validation-caller.yml"
#   PR_BRANCH            e.g. "chore/add-branch-name-validation"
#   GH_TOKEN             fine-grained PAT scoped to loadlink org
#                        (Contents R/W, Pull requests R/W, Workflows R/W)
#
# Steps (in order):
#   1. Deploy WORKFLOW_FILE_PATH to main
#        - Direct commit if allowed; falls back to a PR if main is protected.
#        - Skips entirely if the repo has no 'main' branch.
#   2. Open PR to add file to develop      (best-effort — warns, never fails job)
#
# Idempotent: every step checks current state before acting.

set -euo pipefail

REPO="${MATRIX_REPO}"
DRY_RUN="${DRY_RUN:-false}"
# Separate branch name for PRs targeting main, to avoid conflicts with the
# develop PR branch (which is created from a different base commit).
PR_BRANCH_MAIN="${PR_BRANCH}-to-main"

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
warn() { echo "[$(date -u +%H:%M:%S)] WARN: $*" >&2; }
die()  { echo "[$(date -u +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

log "=== Processing $REPO (dry_run=$DRY_RUN) ==="

local_file="$GITHUB_WORKSPACE/$WORKFLOW_FILE_PATH"
[[ -f "$local_file" ]] || die "Source file not found at: $local_file"

# Pre-encode file content once — reused across steps
content=$(base64 -w 0 "$local_file")

# ─────────────────────────────────────────────────────────────────────────────
# Helper: open a PR to main when direct commits are blocked by branch protection
# Best-effort — any failure logs a warning and returns 0.
# ─────────────────────────────────────────────────────────────────────────────
setup_main_pr() {
  # No open PR already
  pr_count=$(gh pr list \
    --repo "$REPO" \
    --head "$PR_BRANCH_MAIN" \
    --base main \
    --state open \
    --json number \
    --jq 'length' 2>/dev/null || echo "0")
  if [ "${pr_count:-0}" -gt 0 ]; then
    log "Step 1: PR to main already open"
    return 0
  fi

  # File not already on the PR branch
  if gh api "repos/$REPO/contents/$WORKFLOW_FILE_PATH?ref=$PR_BRANCH_MAIN" > /dev/null 2>&1; then
    warn "Step 1: file already on $PR_BRANCH_MAIN but no open PR — may have been merged or closed already"
    return 0
  fi

  # Get main HEAD SHA
  main_sha=$(gh api "repos/$REPO/branches/main" --jq '.commit.sha' 2>/dev/null) || {
    warn "Step 1: could not get main HEAD SHA — skipping PR fallback"
    return 0
  }

  # Create PR branch from main HEAD
  ref_body=$(jq -n \
    --arg ref "refs/heads/$PR_BRANCH_MAIN" \
    --arg sha "$main_sha" \
    '{ref: $ref, sha: $sha}')
  echo "$ref_body" | gh api "repos/$REPO/git/refs" \
    --method POST --input - > /dev/null 2>&1 \
    || log "Note Step 1: branch $PR_BRANCH_MAIN may already exist, continuing"

  # PUT file onto PR branch
  pr_put_body=$(jq -n \
    --arg message "ci: add branch name validation workflow" \
    --arg content "$content" \
    --arg branch  "$PR_BRANCH_MAIN" \
    '{message: $message, content: $content, branch: $branch}')

  echo "$pr_put_body" | gh api "repos/$REPO/contents/$WORKFLOW_FILE_PATH" \
    --method PUT --input - > /dev/null 2>&1 || {
    warn "Step 1: could not commit file to $PR_BRANCH_MAIN — skipping PR fallback"
    return 0
  }

  # Open PR
  pr_url=$(gh pr create \
    --repo "$REPO" \
    --base main \
    --head "$PR_BRANCH_MAIN" \
    --title "ci: add branch name validation workflow" \
    --body "Adds the branch name validation caller workflow to this repo.

Deployed automatically as part of the loadlink branch protection rollout.
The workflow calls the centralised reusable workflow in \`loadlink/.github\`." \
    2>&1) || {
    warn "Step 1: could not create PR to main: $pr_url"
    return 0
  }
  log "Step 1: PR opened to main (requires review) — $pr_url"

  # Try auto-merge (best-effort — only works if branch protection allows it)
  gh pr merge "$PR_BRANCH_MAIN" --repo "$REPO" --auto --squash 2>/dev/null \
    || warn "Step 1: auto-merge not enabled on $REPO/main"

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: open a PR to develop
# Best-effort — any failure logs a warning and returns 0.
# ─────────────────────────────────────────────────────────────────────────────
setup_develop_pr() {
  # 2a. develop branch must exist
  if ! gh api "repos/$REPO/branches/develop" > /dev/null 2>&1; then
    log "SKIP Step 2: no develop branch"
    return 0
  fi

  # 2b. file must not already be on develop
  if gh api "repos/$REPO/contents/$WORKFLOW_FILE_PATH?ref=develop" > /dev/null 2>&1; then
    log "SKIP Step 2: file already exists on develop"
    return 0
  fi

  # 2c. no open PR already
  pr_count=$(gh pr list \
    --repo "$REPO" \
    --head "$PR_BRANCH" \
    --base develop \
    --state open \
    --json number \
    --jq 'length' 2>/dev/null || echo "0")
  if [ "${pr_count:-0}" -gt 0 ]; then
    log "SKIP Step 2: PR already open"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY RUN Step 2: would create $PR_BRANCH and open PR to develop"
    return 0
  fi

  # 2d. get develop HEAD SHA
  develop_sha=$(gh api "repos/$REPO/branches/develop" --jq '.commit.sha' 2>/dev/null) || {
    warn "Step 2: could not get develop HEAD SHA — skipping"
    return 0
  }

  # 2e. create PR branch from develop HEAD (may already exist from a prior failed run)
  ref_body=$(jq -n \
    --arg ref "refs/heads/$PR_BRANCH" \
    --arg sha "$develop_sha" \
    '{ref: $ref, sha: $sha}')
  echo "$ref_body" | gh api "repos/$REPO/git/refs" \
    --method POST --input - > /dev/null 2>&1 \
    || log "Note Step 2: branch $PR_BRANCH may already exist, continuing"

  # 2f. PUT file onto PR branch
  existing_sha=$(gh api "repos/$REPO/contents/$WORKFLOW_FILE_PATH?ref=$PR_BRANCH" \
    --jq '.sha' 2>/dev/null || true)

  if [[ -n "$existing_sha" ]]; then
    put_body=$(jq -n \
      --arg message "ci: add branch name validation workflow" \
      --arg content "$content" \
      --arg branch  "$PR_BRANCH" \
      --arg sha     "$existing_sha" \
      '{message: $message, content: $content, branch: $branch, sha: $sha}')
  else
    put_body=$(jq -n \
      --arg message "ci: add branch name validation workflow" \
      --arg content "$content" \
      --arg branch  "$PR_BRANCH" \
      '{message: $message, content: $content, branch: $branch}')
  fi

  echo "$put_body" | gh api "repos/$REPO/contents/$WORKFLOW_FILE_PATH" \
    --method PUT --input - > /dev/null 2>&1 || {
    warn "Step 2: could not commit file to $PR_BRANCH — skipping"
    return 0
  }

  # 2g. create PR
  pr_url=$(gh pr create \
    --repo "$REPO" \
    --base develop \
    --head "$PR_BRANCH" \
    --title "ci: add branch name validation workflow" \
    --body "Adds the branch name validation caller workflow to this repo.

Deployed automatically as part of the loadlink branch protection rollout.
The workflow calls the centralised reusable workflow in \`loadlink/.github\`." \
    2>&1) || {
    warn "Step 2: could not create PR: $pr_url"
    return 0
  }
  log "SUCCESS Step 2: PR created — $pr_url"

  # 2h. enable auto-merge (best-effort — requires branch protection rules to be set)
  gh pr merge "$PR_BRANCH" --repo "$REPO" --auto --squash 2>/dev/null \
    || warn "Step 2: auto-merge not enabled (branch protection may not be configured)"

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Deploy workflow file to main
# Hard failure — if this fails the matrix job fails (but fail-fast: false means
# other repos still run).
# ─────────────────────────────────────────────────────────────────────────────
log "--- Step 1: Deploy $WORKFLOW_FILE_PATH to main ---"

if gh api "repos/$REPO/contents/$WORKFLOW_FILE_PATH?ref=main" > /dev/null 2>&1; then
  log "SKIP Step 1: file already exists on main"
else
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY RUN Step 1: would deploy $WORKFLOW_FILE_PATH to main of $REPO"
  else
    # Check branch count — skip empty repos and detect access problems.
    if ! branch_count=$(gh api "repos/$REPO/branches" --jq 'length' 2>/dev/null); then
      if ! gh api "repos/$REPO" > /dev/null 2>&1; then
        die "Step 1: REPO_SETUP_TOKEN cannot access $REPO. Verify the fine-grained PAT uses 'loadlink' as the resource owner and has Contents (R/W) and Workflows (R/W) permissions."
      fi
      branch_count=0
    fi

    if [ "${branch_count:-0}" -eq 0 ]; then
      log "SKIP: $REPO has no commits yet — will retry automatically once initialised"
      exit 0
    fi

    # Skip repos that don't use 'main' as their default branch.
    if ! gh api "repos/$REPO/branches/main" > /dev/null 2>&1; then
      default_branch=$(gh api "repos/$REPO" --jq '.default_branch' 2>/dev/null || echo "unknown")
      warn "SKIP: $REPO has no 'main' branch (default branch is '$default_branch') — rename to 'main' to enable this automation"
      log "=== Done: $REPO ==="
      exit 0
    fi

    put_body=$(jq -n \
      --arg message "ci: add branch name validation workflow" \
      --arg content "$content" \
      --arg branch  "main" \
      '{message: $message, content: $content, branch: $branch}')

    if err=$(echo "$put_body" | gh api "repos/$REPO/contents/$WORKFLOW_FILE_PATH" \
               --method PUT --input - 2>&1); then
      log "SUCCESS Step 1: deployed to main"
    elif echo "$err" | grep -qi "422\|already exist"; then
      log "SKIP Step 1: race condition — file appeared during deploy, continuing"
    elif echo "$err" | grep -qi "409\|Repository rule violations\|must be made through a pull request"; then
      warn "Step 1: direct push to main is protected — opening PR instead"
      setup_main_pr
    else
      die "Step 1 failed for $REPO: $err"
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Open PR to add workflow file to develop
# ─────────────────────────────────────────────────────────────────────────────
log "--- Step 2: Open PR to develop ---"

setup_develop_pr

log "=== Done: $REPO ==="
