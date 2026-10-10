# Repository instructions

Read `CLAUDE.md` for the repository's contribution, testing, and release instructions.

## Pull requests

When creating, preparing, or updating a PR, use `.agents/skills/prepare-pr/SKILL.md`. This repository's rules take precedence over a personal PR skill's default title or body format.

Use an English Conventional Commits title and fill out `.github/PULL_REQUEST_TEMPLATE.md` with the actual changes and validation results. Mark checklist items complete only when supported by the work performed.

Every PR with a visible UI change must embed images in `UI changes`: actual screenshots, local renders of the production UI, or clearly labeled illustrations of the changed UI are accepted. Include before/after images for an existing screen; for a new screen, explain that no previous screen exists and include its image. Text alone does not satisfy this requirement. If images are missing, the agent must produce and attach them as part of the authorized PR work without asking the user to supply them. Try suitable generation and attachment alternatives before declaring a blocker. Keep publication pending only when a concrete failure still prevents completion, and report the attempted methods and required user action. Remove `UI changes` only when there is no visible UI change.

## Pull Requests and Remotes
- **Always target the forked repository (`cte13/PokeTokenBar-iOS`) for pull requests.**
- **NEVER** open a pull request against the upstream repository (`chattymin/PokeTokenBar`).
- When creating PRs with `gh`, always verify or explicitly pass `--repo cte13/PokeTokenBar-iOS`.

## Upstream Syncs
- **Preserve Git graph ancestry with upstream (`chattymin/PokeTokenBar:main`).**
- **NEVER** squash-merge upstream sync PRs. Squash-merging severs the commit graph and makes GitHub report phantom "commits behind" counts.
- For upstream syncs, always create/merge via standard merge commits (`git merge upstream/main` or merge PRs with "Create a merge commit") so the merge base advances and GitHub reflects 0 commits behind.
