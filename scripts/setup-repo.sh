#!/usr/bin/env bash
# setup-repo.sh — deploys branch-name-validation workflow to a single org repo.
#
# Called by repo-setup-automation.yml with the following env vars injected:
#   MATRIX_REPO          e.g. "loadlink/my-repo"
#   DRY_RUN              "true" | "false"
#   WORKFLOW_FILE_PATH   e.g. ".github/workflows/branch-name-validation-caller.yml"
#   PR_BRANCH            e.g. "chore/add-branch-name-validation"
#   GH_TOKEN             fine-grained PAT scoped to loadlink org (Contents R/W, Pull requests R/W)
#
# Steps (in order):
#   1. Deploy WORKFLOW_FILE_PATH to main   (hard failure)
#   2. Open PR to add file to develop      (best-effort — warns, never fails job)
#
# Idempotent: every step checks current state before acting.

set -euo pipefail

REPO="${MATRIX_REPO}"
DRY_RUN="${DRY_RUN:-false}"

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
warn() { echo "[$(date -u +%H:%M:%S)] WARN: $*" >&2; }
die()  { echo "[$(date -u +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

log "=== Processing $REPO (dry_run=$DRY_RUN) ==="

local_file="$GITHUB_WORKSPACE/$WORKFLOW_FILE_PATH"
[[ -f "$local_file" ]] || die "Source file not found at: $local_file"

# Pre-encode file content once — reused in Steps 1 and 2
content=$(base64 -w 0 "$local_file")

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
    # Check if the repo has any commits at all.
    # Empty repos (no branches) need the Git Data API because the Contents API
    # requires an existing git ref to base the commit on.
    #
    # NOTE: || must be OUTSIDE $() to avoid concatenating the error JSON with "0".
    #       Inside $(): cmd || echo "0" captures both stdout streams into the var.
    #       Outside $(): the assignment is overwritten only if the command failed.
    if ! branch_count=$(gh api "repos/$REPO/branches" --jq 'length' 2>/dev/null); then
      # Branches API failed — check whether this is a token access problem
      if ! gh api "repos/$REPO" > /dev/null 2>&1; then
        die "Step 1: REPO_SETUP_TOKEN cannot access $REPO (HTTP 404). Verify the fine-grained PAT uses 'loadlink' as the resource owner and has Contents (R/W) permission."
      fi
      branch_count=0
    fi

    if [ "${branch_count:-0}" -eq 0 ]; then
      # GitHub's API (Contents and Git Data) rejects all writes to repos with
      # zero commits. Skip cleanly and let the scheduler retry — once someone
      # pushes the first commit the repo will be picked up automatically.
      log "SKIP: $REPO has no commits yet — will retry automatically once initialised"
      exit 0

    else
      # Normal case — repo has commits, use the Contents API
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
      else
        die "Step 1 failed for $REPO: $err"
      fi
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Open PR to add workflow file to develop
# Best-effort — any failure logs a warning and returns 0.
# ─────────────────────────────────────────────────────────────────────────────
log "--- Step 2: Open PR to develop ---"

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
  #     If branch existed from a prior run the file may already be there — include
  #     its SHA to satisfy the "update" requirement, otherwise omit it (new file).
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

setup_develop_pr

log "=== Done: $REPO ==="
