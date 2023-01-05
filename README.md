# update-and-push-action
Github action updating target repository with files from local directory

Inspired by [github-action-push-to-another-repository](https://github.com/cpina/github-action-push-to-another-repository)

Input parameters:

| Name | Required      | Default | Purpose |
| ---- | ------------- | ------- | ------- |
| source-directory     | No  | . | Directory to use as the base for target update |
| target-user          | No  | (owner of the source repository)  | Name of the username/organization owning the target repository |
| target-repository    | Yes |   | Name of the target repository |
| commit-email         | Yes |   | E-mail address to use in the commit to the target repository |
| target-server        | No  | (same as source repo) | Target git server |
| target-branch        | No  | main | Target branch name |
| commit-message       | No  | Update from ${ORIGIN_COMMIT} | Commit message template. ${ORIGIN_COMMIT} is replaced by the URL@commit in the origin repo triggering the action |
| target-directory     | No  | (root of repository) | Directory in the target repository to update |
| create-target-branch | No  | False | Boolean indicating whether to create the target branch if it does not exist |
| exclude-filter       | No  |       | Name of file containing rsync-style exlude list |

## Authentication and permissions

Access to the target repository may be authenticated either by using `${SSH_DEPLOY_KEY}` or `${API_GITHUB_TOKEN}` from the environment.
SSH key is preferred if available. The identity associated with the secret must have permissions for the target repository:
- Read access to metadata
- Read and Write access to code and pull requests

## Usage examples

### Mirror current branch in the source repository to the target repo

```
name: Update target repo

on:
  push:

jobs:
  build:
    runs-on: ubuntu-latest

    # Allow the job to fetch a GitHub ID token
    permissions:
      contents: 'read'
      id-token: 'write'

    steps:
      - name: Checkout sources
        uses: actions/checkout@v3
      - name: Update target repo
        uses: kentik/update-and-push-action@main
        env:
          API_TOKEN_GITHUB: ${{ secrets.TARGET_ACCESS_TOKEN }}
        with:
          target-user: kentik
          target-repository: target
          commit-email: builds@kentik.com
          target-branch: ${{ github.ref_name }}
          create-target-branch: true
          exclude-filter: .github/workflow/update_exclude_filter
```
Content of `.github/workflow/update_exclude_filter`:
```
/.github/
```

### Update the `main` branch in the target repository with files in a `export` directory while preserving README.md and .github
```
name: Update target repo

on:
  push:

jobs:
  build:
    runs-on: ubuntu-latest

    # Allow the job to fetch a GitHub ID token
    permissions:
      contents: 'read'
      id-token: 'write'

    steps:
      - name: Checkout sources
        uses: actions/checkout@v3
      - name: Update target repo
        uses: kentik/update-and-push-action@main
        env:
          API_TOKEN_GITHUB: ${{ secrets.TARGET_ACCESS_TOKEN }}
        with:
          source-directory: export
          target-user: kentik
          target-repository: target
          commit-email: builds@kentik.com
          exclude-filter: .github/workflow/update_exclude_filter
```
Content of `.github/workflow/update_exclude_filter`:
```
/.github/
/README.md
```
