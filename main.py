import logging
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from tempfile import NamedTemporaryFile, TemporaryDirectory
from typing import Callable, List, Optional

import yaml

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger()


class Args:
    def __init__(self, action_spec: str):
        self.debug = False
        if os.environ.get("RUNNER_DEBUG"):
            self.debug = True
        self.debug_work_dir = os.environ.get("DEBUG_WORK_DIR")
        self.ssh_key = os.environ.get("SSH_DEPLOY_KEY")
        self.api_token = os.environ.get("API_TOKEN_GITHUB")
        server_url = os.environ.get("GITHUB_SERVER_URL")
        orig_repo = os.environ.get("GITHUB_REPOSITORY")
        orig_sha = os.environ.get("GITHUB_SHA")
        if server_url and orig_repo and orig_sha:
            self.origin_commit = f"{server_url}/{orig_repo}/commit/{orig_sha}"
        else:
            self.origin_commit = ""
        with Path(action_spec).open() as f:
            action = yaml.safe_load(f)
        for a, d in action["inputs"].items():
            key = f"INPUT_{a.upper()}"
            log.debug(
                "input: %s key: %s default: %s env: %s",
                a,
                key,
                d.get("default"),
                os.environ.get(key),
            )
            setattr(self, a, os.environ.get(key, d.get("default")))
            if getattr(self, a) is None:
                fail(f"Missing required input argument: '{a}'")
        # fix-ups
        if not self.target_user:
            self.target_user = os.environ.get("GITHUB_REPOSITORY_OWNER")
            if not self.target_user:
                fail("No 'target_user' specified and 'GITHUB_REPOSITORY_OWNER' not present in environment")
                return
            log.debug("Set 'target_user' from 'GITHUB_REPOSITORY_OWNER'")
        if not self.target_server:
            self.target_server = os.environ.get("GITHUB_SERVER_URL")
            if not self.target_server:
                fail("No 'target_server' specified and 'GITHUB_SERVER_URL' not present in environment")
                return
            # remove leading protocol specification from the target_server
            self.target_server = self.target_server.split("//")[1]
            log.debug("Set 'target_server' from 'GITHUB_SERVER_URL'")


args: Optional[Args] = None


def fail(msg: str):
    log.error(msg)
    exit(1)


def info(msg: str):
    log.info(msg)


def run_cmd(cmd: List[str]) -> bool:
    ret = subprocess.call(cmd)
    if ret:
        fail(f"Command: {' '.join(cmd)} failed, err: {ret}")
    return ret == 0


def list_dir_recursive(d: Path, reporter: Callable[[str], None]):
    for f in d.iterdir():
        reporter(f.as_posix())
        if f.is_dir():
            list_dir_recursive(f, reporter)


def copy_files(sources: List[str], destination: str, clone_dir: str):
    missing_sources = [p for p in sources if not Path(p).exists()]
    if missing_sources:
        fail(f"Following sources do not exist: {', '.join([str(e) for e in missing_sources])}")
        return
    target = os.path.sep.join([clone_dir, destination])
    info(f"Copying {', '.join(sources)} to {target}")
    target_parent = Path(target).parent
    if not target_parent.is_dir():
        log.debug("Creating: %s", target_parent.as_posix())
        target_parent.mkdir(parents=True, exist_ok=True)
    rsync = ["rsync", "-r", "--delete", "--exclude", "/.git"]
    if args.debug:
        rsync.append("-v")
    if args.exclude_filter:
        rsync.append("--exclude-from")
        rsync.append(args.exclude_filter)
    for p in sources:
        rsync.append(p)
    rsync.append(target)
    log.debug("rsync cmd: %s", rsync)
    run_cmd(rsync)
    # run_cmd terminates the whole process if the command fails


def apply_transfer_map(map_file: Path, clone_dir: str):
    if not map_file.exists():
        fail(f"Transfer map file '{map_file.as_posix()}' does not exist")
        return
    info(f"Using transfer map: {map_file.as_posix()}")
    # Parse transfer map file
    target_map = defaultdict(list)

    log.debug("Parsing transfer map: %s", map_file.as_posix())
    parse_error = False
    for n, line in enumerate([e.strip() for e in map_file.open()], start=1):
        if not line:
            log.debug("skipping empty line: %d", n)
            continue
        if re.match(r"^\w*#", line):
            log.debug("skipping comment line: %d: %s", n, line)
            continue
        m = re.match(r"([^ \t]+) ([^ \t#]+)(/w*#.*)*", line)
        if not m:
            log.error("line: %d: invalid format %s ", n, line)
            parse_error = True
            continue
        src = m.groups()[0]
        dst = m.groups()[1]
        invalid = [e for e in (src, dst) if ".." in e]
        if invalid:
            parse_error = True
            log.error("line: %d invalid paths (must not contain '..'): %s", n, invalid)
            continue
        log.debug("%4d: src: %s dst: %s", n, src, dst)
        target_map[dst].append(src)
    if parse_error:
        fail("Invalid transfer map")
        return
    # sort keys by path length
    targets = sorted([t for t in target_map.keys()], key=lambda x: len(Path(x).parts))
    log.debug("target_map:")
    if args.debug:
        for n, t in enumerate(targets, start=1):
            log.debug("%4d: dst: %s\t src: %s", n, t, " ".join(target_map[t]))
    for t in targets:
        if args.source_directory != ".":
            sources = [os.path.sep.join([args.source_directory, s]) for s in target_map[t]]
        else:
            sources = target_map[t]
        if args.target_directory and args.target_directory != ".":
            target = os.path.sep.join([args.target_directory, t])
        else:
            target = t
        copy_files(sources, target, clone_dir)


def setup_ssh():
    info("Using SSH_DEPLOY_KEY")
    args.key = NamedTemporaryFile("w")
    args.known_hosts = NamedTemporaryFile("w")

    args.key.file.write(args.ssh_key)
    args.key.flush()
    log.debug("Wrote SSH_DEPLOY_KEY to '%s'", args.key.name)
    try:
        args.known_hosts.file.write(
            subprocess.check_output(["ssh-keyscan", "-H", "github.com"], stderr=subprocess.DEVNULL).decode("utf-8")
        )
        args.known_hosts.flush()
    except subprocess.CalledProcessError as ex:
        fail(f"ssh-keyscan failed: {ex}")
        return
    log.debug("Wrote known hosts to '%s'", args.known_hosts.name)
    os.environ["GIT_SSH_COMMAND"] = f"ssh -i {args.key.name} -o UserKnownHostsFile={args.known_hosts.name}"


def main():
    global args
    if os.environ.get("RUNNER_DEBUG"):
        log.setLevel(logging.DEBUG)
        log.debug("Python version: %s", sys.version)
    log.debug("Workdir: %s", Path.cwd())
    args = Args("/action.yml")
    log.debug("args: %s", args.__dict__)
    if args.debug_work_dir:
        os.chdir(args.debug_work_dir)

    # setup authentication
    # sanity check
    if not args.ssh_key and not args.api_token:
        fail("Either 'SSH_DEPLOY_KEY' or 'API_TOKEN_GITHUB' must be present in the environment.")
        return
    if args.ssh_key:
        setup_ssh()
        git_url = f"git@{args.target_server}:{args.target_user}/{args.target_repository}.git"
    else:
        p = "/".join([args.target_server, args.target_user, args.target_repository])
        git_url = f"https://{args.target_user}:{args.api_token}@{p}"
    log.debug("git_url: %s", git_url)
    # setup git
    if args.debug:
        try:
            log.debug(
                "git version: %s",
                subprocess.check_output(["git", "--version"]).decode("utf-8"),
            )
        except subprocess.CalledProcessError as ex:
            log.error("git version failed: %s", ex)
    for attr, val in (
        ("user.email", args.commit_email),
        ("user.name", args.target_user),
    ):
        run_cmd(["git", "config", "--global", attr, val])
    run_cmd(["git", "config", "--global", "--add", "safe.directory", "/github/workspace"])

    # clone the target repo
    info(f"Cloning repository '{args.target_repository}'")
    if args.debug:
        if git_url.startswith("git@"):
            log.debug("GIT_SSH_COMMAND: %s", os.environ["GIT_SSH_COMMAND"])
            log.debug("key: %s (exists: %s)", args.key.name, Path(args.key.name).exists())
            log.debug("known_hosts: %s (exists: %s)", args.known_hosts.name, Path(args.known_hosts.name).exists())

    with TemporaryDirectory() as clone_dir:
        new_branch = False
        run_cmd(["git", "config", "--global", "--add", "safe.directory", clone_dir])
        log.debug("Set clone_dir: '%s' as safe", clone_dir)
        ret = subprocess.call(
            [
                "git",
                "clone",
                "--single-branch",
                "--depth",
                "1",
                "--branch",
                args.target_branch,
                git_url,
                clone_dir,
            ]
        )
        if ret and args.create_target_branch:
            # branch did not exist, clone the main branch
            ret = subprocess.call(["git", "clone", "--single-branch", "--depth", "1", git_url, clone_dir])
            if ret:
                fail(f"Failed to clone the target repository: {args.target_repository} branch: {args.target_branch}")
                return
            # create new branch
            info(f"Creating new branch: {args.target_branch}")
            run_cmd(["git", "branch", args.target_branch])
            run_cmd(["git", "switch", args.target_branch])
            new_branch = True

        # copy files
        if args.transfer_map:
            apply_transfer_map(Path(args.transfer_map), clone_dir)
        else:
            copy_files(
                [f"{args.source_directory}{os.path.sep}"],
                args.target_directory,
                clone_dir,
            )

        # commit changes, if any
        os.chdir(clone_dir)
        log.debug("Changed workdir to: %s", Path.cwd())

        info("Adding commit")
        run_cmd(["git", "add", "."])

        if args.debug:
            try:
                status = subprocess.check_output(["git", "status"]).decode("utf-8")
                log.debug("git status: %s", status)
            except subprocess.CalledProcessError as ex:
                log.error("Failed to run git status: %s", ex)

        # Avoid the git commit failure if there are no changes to commit
        ret = subprocess.call(["git", "diff-index", "--quiet", "HEAD"])
        log.debug("git diff-index returned: %d", ret)
        if ret == 0:
            # no changes to commit
            info("No changes to commit")
            if not new_branch:
                exit(0)

        # Construct commit message
        # It is constructed by evaluating string from configuration which may insert environment variables
        # We also promise to put ORIGIN_COMMIT in the environment
        os.environ["ORIGIN_COMMIT"] = args.origin_commit
        try:
            msg = subprocess.check_output(["sh", "-c", f"eval echo {args.commit_message}"]).decode("utf-8")
        except subprocess.CalledProcessError as ex:
            fail(f"Failed to construct commit message: {ex}")
        log.debug("Commit message: %s", msg)
        run_cmd(["git", "commit", "--message", msg])

        # Push commit to repo
        info("Pushing git commit")
        # --set-upstream: sets de branch when pushing to a branch that does not exist
        run_cmd(["git", "push", git_url, "--set-upstream", args.target_branch])


if __name__ == "__main__":
    main()
