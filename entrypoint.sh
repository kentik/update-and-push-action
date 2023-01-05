#!/bin/sh -l

set -e # if a command fails it stops the execution
set -u # script fails if trying to access to an undefined variable

echo "[+] Action start"
SOURCE_DIRECTORY="${1}"
TARGET_USER="${2}"
TARGET_REPOSITORY="${3}"
TARGET_SERVER="${4}"
COMMIT_EMAIL="${5}"
TARGET_BRANCH="${6}"
COMMIT_MESSAGE="${7}"
TARGET_DIRECTORY="${8}"
CREATE_TARGET_BRANCH="${9}"
EXCLUDE_FILTER="${10}"

if [ -z "${TARGET_SERVER}" ]; then
	TARGET_SERVER=${GITHUB_SERVER}
fi

if [ -n "${SSH_DEPLOY_KEY}" ]; then
	echo "[+] Using SSH_DEPLOY_KEY"

	# Inspired by https://github.com/leigholiver/commit-with-deploy-key/blob/main/entrypoint.sh , thanks!
	mkdir --parents "${HOME}/.ssh"
	key_file="${HOME}/.ssh/deploy_key"
	echo "${SSH_DEPLOY_KEY}" >${key_file}
	chmod 600 ${key_file}

	known_hosts_file="${HOME}/.ssh/known_hosts"
	ssh-keyscan -H "${TARGET_SERVER}" >${known_hosts_file}

	export GIT_SSH_COMMAND="ssh -i ${key_file} -o UserKnownHostsFile=${known_hosts_file}"

	git_url="git@${TARGET_SERVER}:${TARGET_USER}/${TARGET_REPOSITORY}.git"

elif [ -n "${API_TOKEN_GITHUB}" ]; then
	echo "[+] Using API_TOKEN_GITHUB"
	git_url="https://${TARGET_USER}:${API_TOKEN_GITHUB}@${TARGET_SERVER}/${TARGET_USER}/${TARGET_REPOSITORY}.git"
else
	echo "::error::Neither API_TOKEN_GITHUB nor SSH_DEPLOY_KEY available."
	exit 1
fi

if [ -n "${EXCLUDE_FILTER}" -a ! -f ${EXCLUDE_FILTER} ]; then
	echo "::error::The exclude filter file '${EXCLUDE_FILTER}' does not exist"
	exit 1
fi

clone_dir=$(mktemp -d)
new_branch=0

echo "[+] Git version"
git --version

# Setup git
git config --global user.email "${COMMIT_EMAIL}"
git config --global user.name "${TARGET_USER}"
git config --global --add safe.directory /github/workspace

echo "[+] Cloning repository ${TARGET_REPOSITORY}"

if ! git clone --single-branch --depth 1 --branch ${TARGET_BRANCH} ${git_url} ${clone_dir}; then
	if ${CREATE_TARGET_BRANCH} && git clone --single-branch --depth 1 ${git_url} ${clone_dir}; then
		new_branch=1
	else
		echo "::error::Could not clone the target repository."
		echo -n "::error::Please verify that the target repository exists and is accesible with your API_TOKEN_GITHUB or SSH_DEPLOY_KEY"
		if ${CREATE_TARGET_BRANCH}; then
			echo "."
		else
			echo ""
			echo "::error::and that it contains the target branch ('${TARGET_BRANCH}')."
		fi
		exit 1
	fi
fi

echo "[+] Set cloned repo as safe (${clone_dir})"
# Related to https://github.com/cpina/github-action-push-to-another-repository/issues/64 and https://github.com/cpina/github-action-push-to-another-repository/issues/64
# TODO: review before releasing it as a version
git config --global --add safe.directory "${clone_dir}"

echo "[+] Checking if ${SOURCE_DIRECTORY} exists"
if [ ! -d "${SOURCE_DIRECTORY}" ]; then
	echo "::error::${SOURCE_DIRECTORY} does not exist"
	echo "::error::It must exist in the GITHUB_WORKSPACE when this action is executed."
	exit 1
fi

target_dir=${clone_dir}/${TARGET_DIRECTORY}

excludes="--exclude /.git"
if [ -n "${EXCLUDE_FILTER}" ]; then
	excludes="${excludes} --exclude-from ${EXCLUDE_FILTER}"
fi
echo "[+] Copying contents of ${SOURCE_DIRECTORY} to ${target_dir}"
rsync -v -r --delete ${excludes} ${SOURCE_DIRECTORY}/ ${target_dir}/

echo "[+] Target directory after update:"
ls -la ${target_dir}

# Commit any changes and push them to the target repo
cd ${clone_dir}

if [ ${new_target_branch} -ne 0 ]; then
	echo "[+] Creating target branch ${TARGET_BRANCH}"
	git branch ${TARGET_BRANCH}
	git switch ${TARGET_BRANCH}
fi

echo "[+] Adding git commit"
git add .

echo "[+] git status:"
git status

# Avoid the git commit failure if there are no changes to commit
if diff-index --quiet HEAD; then
	echo "[+] No changes to commit"
	exit 0
fi

ORIGIN_COMMIT="https://${GITHUB_SERVER}/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA}"
msg=$(eval echo $COMMIT_MESSAGE)
git commit --message "${msg}"

echo "[+] Pushing git commit"
# --set-upstream: sets de branch when pushing to a branch that does not exist
git push ${git_url} --set-upstream "${TARGET_BRANCH}"
