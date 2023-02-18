# update-and-push-action
Github action updating target repository with files from local directory.

**Inspired by [github-action-push-to-another-repository](https://github.com/cpina/github-action-push-to-another-repository)**

This action expects the source tree (provider of the `source_directory`) to be checked out in the workspace.

The action performs following steps:
1. checks out the `target_branch` from the `target_repository` into temporary directory 
2. if no `transfer_map` is provided, copies all files and directories from `source_directory` to `target_directory`
   using `rsync`. The rsync command deletes extraneous files and directories from the destination directory unless they
   are matched by an entry in the `exclude_filter` file. The `.git` directory is always excluded. 
3. if `transfer_map` is specified, copies all files and directories from `src` to the `dst` for every entry in the
   `transfer_map` file. Transfer map syntax is described bellow. Source paths in the `transfer_map` are relative to
   the `source_directory`. Destination paths are relative to the `target_directory`. 
4. commits modified tree to the `target_branch` of the `target_repository`
5. pushes commits to the `target_repository`

If the `create_target_branch` argument is set to `True` the `target_branch` is created in the `target_repository` if it does not exist.
The `commit_message` argument allows to provide a template for the commite message to the target repository. The `${ORIGIN_COMMIT}` variable
is expanded to reference to the commit to the origin repo which has triggered the action. Any other environment variables provided
to the Github action are expanded in the `commit_message` template.

## Transfer map syntax

The `tranfer_map` files allows to describe simple transformations of source tree before commiting it to `target_repository`.
Each line in the file is expected to contain 2 strings `source` and `destination` separated by whitespace.
Lines starting with `#` are treated as comments and ignored as well as any trailing text after after `#`.
`source` nor `destination` must not contain `..`.
Extracted `source` and `destination` are directly passed as arguments to `rsync`

Examples of transfer map:
- simplest possible
```
# copy entire source tree to target
. .
```
- copy content of directory `my_code`  to `new_code`
```
my_code/ new_code # this is comment

# copy single file to different location
docs/README.md new_code/README.new.md
```
- copy complete source tree to `import/src` 
```
   # also treated as a comment
. import/src
```

## Input arguments

| Name | Required | Default | Purpose |
| ---- | ---------| ------- | ------- |
| `transfer_map` | No | | Name of tranfer map file |
| `source_directory`| No | . | Directory providing content for the update |
| `target_user` | No | (owner of the source repository) | Name of the username/organization owning the target repository |
| `target_repository`| Yes | | Name of the target repository. It must exist |
| `commit_email` | Yes | | E-mail address to use in the commit to the target repository |
| `target_server` | No | (same as source repo) | Target git server |
| `target_branch` | No | main | Target branch name |
| `commit_message` | No | Update from ${ORIGIN_COMMIT} | Commit message template |
| `target_directory` | No | (root of repository) | Directory in the target repository to update |
| `create_target_branch` | No | False | Boolean indicating whether to create the target branch if it does not exist |
| `exclude_filter` | No | | Name of file containing rsync-style exlude list |

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
