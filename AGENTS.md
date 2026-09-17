# Repository instructions

Read `CLAUDE.md` for the repository's contribution, testing, and release instructions.

## Pull requests

Before creating or updating a PR, read `.github/PULL_REQUEST_TEMPLATE.md` and use its sections and checklist in the description. Fill in the type of change and the actual validation results. For UI changes, include the before/after comparison; remove the UI section only when there are no UI changes. Mark checklist items complete only when supported by the work performed. Keep the PR title and description in English.

## Pull Requests and Remotes
- **Always target the forked repository (`cte13/PokeTokenBar-iOS`) for pull requests.**
- **NEVER** open a pull request against the upstream repository (`chattymin/PokeTokenBar`).
- When creating PRs with `gh`, always verify or explicitly pass `--repo cte13/PokeTokenBar-iOS`.

## Upstream Syncs
- **Preserve Git graph ancestry with upstream (`chattymin/PokeTokenBar:main`).**
- **NEVER** squash-merge upstream sync PRs. Squash-merging severs the commit graph and makes GitHub report phantom "commits behind" counts.
- For upstream syncs, always create/merge via standard merge commits (`git merge upstream/main` or merge PRs with "Create a merge commit") so the merge base advances and GitHub reflects 0 commits behind.
