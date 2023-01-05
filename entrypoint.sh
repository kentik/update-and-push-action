#!/bin/sh
set -e # if a command fails it stops the execution

echo "[+] Action start"

if [ -n "${RUNNER_DEBUG}" ]; then
	cat <<-EOF
		arguments:
		----------
		$(env | grep "^INPUT_*")

		environment:
		------------
		$(env)
	EOF
fi

if [ -z "${INPUT_TARGET_USER}" ]; then
	INPUT_TARGET_USER=${GITHUB_REPOSITORY_OWNER}
fi
if [ -z "${INPUT_TARGET_SERVER}" ]; then
	INPUT_TARGET_SERVER=${GITHUB_SERVER_URL##*/}
fi

if [ -n "${SSH_DEPLOY_KEY}" ]; then
	echo "[+] Using SSH_DEPLOY_KEY"

	# Inspired by https://github.com/leigholiver/commit-with-deploy-key/blob/main/entrypoint.sh , thanks!
	mkdir --parents "${HOME}/.ssh"
	key_file="${HOME}/.ssh/deploy_key"
	echo "${SSH_DEPLOY_KEY}" >${key_file}
	chmod 600 ${key_file}

	known_hosts_file="${HOME}/.ssh/known_hosts"
	ssh-keyscan -H "${INPUT_TARGET_SERVER}" >${known_hosts_file}

	export GIT_SSH_COMMAND="ssh -i ${key_file} -o UserKnownHostsFile=${known_hosts_file}"

	git_url="git@${INPUT_TARGET_SERVER}:${INPUT_TARGET_USER}/${INPUT_TARGET_REPOSITORY}.git"

elif [ -n "${API_TOKEN_GITHUB}" ]; then
	echo "[+] Using API_TOKEN_GITHUB"
	git_url="https://${INPUT_TARGET_USER}:${API_TOKEN_GITHUB}@${INPUT_TARGET_SERVER}/${INPUT_TARGET_USER}/${INPUT_TARGET_REPOSITORY}.git"
else
	echo "::error::Neither API_TOKEN_GITHUB nor SSH_DEPLOY_KEY available."
	exit 1
fi

if [ -n "${INPUT_EXCLUDE_FILTER}" -a ! -f ${INPUT_EXCLUDE_FILTER} ]; then
	echo "::error::The exclude filter file '${INPUT_EXCLUDE_FILTER}' does not exist"
	exit 1
fi

clone_dir=$(mktemp -d)
new_branch=0

if [ -n "${RUNNER_DEBUG}" ]; then
	echo "[+] Git version"
	git --version
fi

# Setup git
git config --global user.email "${INPUT_COMMIT_EMAIL}"
git config --global user.name "${INPUT_TARGET_USER}"
git config --global --add safe.directory /github/workspace

echo "[+] Cloning repository ${INPUT_TARGET_REPOSITORY}"

if ! git clone --single-branch --depth 1 --branch ${INPUT_TARGET_BRANCH} ${git_url} ${clone_dir}; then
	if ${INPUT_CREATE_TARGET_BRANCH} && git clone --single-branch --depth 1 ${git_url} ${clone_dir}; then
		new_branch=1
	else
		echo "::error::Could not clone the target repository."
		echo -n "::error::Please verify that the target repository exists and is accesible with your API_TOKEN_GITHUB or SSH_DEPLOY_KEY"
		if ${INPUT_CREATE_TARGET_BRANCH}; then
			echo "."
		else
			echo ""
			echo "::error::and that it contains the target branch ('${INPUT_TARGET_BRANCH}')."
		fi
		exit 1
	fi
fi

if [ -n "${RUNNER_DEBUG}" ]; then
	echo "[+] Set cloned repo as safe (${clone_dir})"
fi

# Related to https://github.com/cpina/github-action-push-to-another-repository/issues/64 and https://github.com/cpina/github-action-push-to-another-repository/issues/64
# TODO: review before releasing it as a version
git config --global --add safe.directory "${clone_dir}"

echo "[+] Checking if ${INPUT_SOURCE_DIRECTORY} exists"
if [ ! -d "${INPUT_SOURCE_DIRECTORY}" ]; then
	echo "::error::Source directory '${INPUT_SOURCE_DIRECTORY}' does not exist"
	echo "::error::It must exist in the GITHUB_WORKSPACE when this action is executed."
	exit 1
fi

target_dir=${clone_dir}/${INPUT_TARGET_DIRECTORY}

excludes="--exclude /.git"
if [ -n "${INPUT_EXCLUDE_FILTER}" ]; then
	excludes="${excludes} --exclude-from ${INPUT_EXCLUDE_FILTER}"
fi
echo "[+] Copying contents of source directory '${INPUT_SOURCE_DIRECTORY}' to target tree '${target_dir}'"
if [ -n "${RUNNER_DEBUG}" ]; then
	rsync_extra_args="-v"
fi
rsync ${rsync_extra_args} -r --delete ${excludes} ${INPUT_SOURCE_DIRECTORY}/ ${target_dir}/

if [ -n "${RUNNER_DEBUG}" ]; then
	echo "[+] Target directory after update:"
	ls -la ${target_dir}
fi

# Commit any changes and push them to the target repo
cd ${clone_dir}

if [ ${new_branch} -ne 0 ]; then
	echo "[+] Creating target branch '${INPUT_TARGET_BRANCH}'"
	git branch ${INPUT_TARGET_BRANCH}
	git switch ${INPUT_TARGET_BRANCH}
fi

echo "[+] Adding git commit"
git add .

if [ -n "${RUNNER_DEBUG}" ]; then
	echo "[+] git status:"
	git status
fi

# Avoid the git commit failure if there are no changes to commit
if git diff-index --quiet HEAD; then
	echo "[+] No changes to commit"
	if [ ${new_branch} -eq 0 ]; then
		exit 0
	fi
else
	ORIGIN_COMMIT="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA}"
	msg=$(eval echo $INPUT_COMMIT_MESSAGE)
	if [ -n "${RUNNER_DEBUG}" ]; then
		echo "[+] commit message: '${msg}'"
	fi

	git commit --message "${msg}"
fi

echo "[+] Pushing git commit"
# --set-upstream: sets de branch when pushing to a branch that does not exist
git push ${git_url} --set-upstream "${INPUT_TARGET_BRANCH}"
