# LoadLink Organization Shared Workflows

This repository contains reusable GitHub Actions workflows shared across all LoadLink repositories.

## Branch Name Validation

The `branch-name-validation.yml` workflow enforces branch naming conventions:

### Supported Branch Patterns

- **Release branches**: `releases/vX.Y.Z-rcN` (e.g., `releases/v2.5.0-rc1`)
  - Release candidate suffix (-rcN) is required
- **Hotfix branches**: `hotfix-vX.Y.Z` (e.g., `hotfix-v1.0.1`)
- **Support branches**: `support/vX.Y.x` (e.g., `support/v1.0.x`)
- **Feature branches**: `feature/JIRA-KEY` (e.g., `feature/DATINT-8`)
  - Supports multiple Jira keys: `feature/LJST-1_LJST-2`
  - Supports optional descriptions: `feature/LJST-1_FixLoginBug`
  - Use underscore (_) as delimiter, not dash

### Usage in Your Repository

Add this caller workflow to your repository at `.github/workflows/branch-name-validation-caller.yml`:

```yaml
name: Branch Name Validation

on:
  pull_request:
    types: [opened, synchronize, reopened, edited]

jobs:
  validate:
    uses: loadlink/.github/.github/workflows/branch-name-validation.yml@main
    with:
      branch_name: ${{ github.head_ref }}
```

### Configuration

To enforce this validation:

1. Go to your repository settings → Rules → Rulesets
2. Create or edit a ruleset targeting your protected branches
3. Add status check requirement: `validate / Branch Name Validation`

## Adding New Workflows

When adding new reusable workflows to this repository:

1. Create workflow files in `.github/workflows/`
2. Use `workflow_call` trigger for reusable workflows
3. Document usage in this README
4. Test in a single repository before org-wide deployment
