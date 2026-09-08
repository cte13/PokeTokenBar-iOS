# Repository Guidelines

## Pull Requests and Remotes
- **Always target the forked repository (`cte13/PokeTokenBar-iOS`) for pull requests.**
- **NEVER** open a pull request against the upstream repository (`chattymin/PokeTokenBar`).
- When creating PRs with `gh`, always verify or explicitly pass `--repo cte13/PokeTokenBar-iOS`.

## Upstream Syncs
- **Preserve Git graph ancestry with upstream (`chattymin/PokeTokenBar:main`).**
- **NEVER** squash-merge upstream sync PRs. Squash-merging severs the commit graph and makes GitHub report phantom "commits behind" counts.
- For upstream syncs, always create/merge via standard merge commits (`git merge upstream/main` or merge PRs with "Create a merge commit") so the merge base advances and GitHub reflects 0 commits behind.
