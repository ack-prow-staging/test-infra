#!/bin/bash

set -eo pipefail


USAGE="
Usage:
  $(basename "$0")

Environment variables:
  GITHUB_ACTOR:        Name of the GitHub account creating the issues & PR.
  GITHUB_TOKEN:        Personal Access Token for '$GITHUB_ACTOR'
  GITHUB_ORG:          Name of the GitHub organization.
  GITHUB_EMAIL_PREFIX  Email prefix to use for GitHub commits.
  PR_TARGET_BRANCH:    Name of the GitHub branch where the PR should merge the
                       code. Defaults to 'main'
"

# Default values
SERVICE=""
RESOURCE=""
SCRIPT_NAME="prow-job.sh"



# Parse command line arguments
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --service)
      SERVICE="$2"
      shift 2
      ;;
    --resource)
      RESOURCE="$2"
      shift 2
      ;;
    *)
      # Unknown option
      shift
      ;;
  esac
done

# Validate that service and resource are set
if [ -z "$SERVICE" ]; then
  echo "Error: --service argument is required"
  exit 1
fi

if [ -z "$RESOURCE" ]; then
  echo "Error: --resource argument is required"
  exit 1
fi

DEFAULT_PR_TARGET_BRANCH="main"
PR_TARGET_BRANCH=${PR_TARGET_BRANCH:-$DEFAULT_PR_TARGET_BRANCH}
# Resolve the workflow package dir from this script's own location, NOT $(pwd):
# once the job declares extra_refs, Prow's decoration runs the entrypoint from a
# clonerefs checkout dir (an extra_ref) rather than the image's /app, so `pwd`
# would point at code-generator and `python -m workflows` would fail / import the
# wrong packages.
WORKFLOW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOB_USER="prow"
SERVICE_REPO=$SERVICE-controller
ORG_REPO=$GITHUB_ORG/$SERVICE-controller
REPO_ROOT="/home/$JOB_USER/${TEST_INFRA_ORG}"
SERVICE_REPO_DIR="$REPO_ROOT/$SERVICE-controller"
LOCAL_GIT_BRANCH=$SERVICE-add-$RESOURCE
PR_SOURCE_BRANCH=$LOCAL_GIT_BRANCH

echo "$SCRIPT_NAME][INFO] Running resource-addition workflow for service: $SERVICE, resource: $RESOURCE"
echo "$SCRIPT_NAME][INFO] Target repository: $GITHUB_ORG/$SERVICE-controller"

USER_EMAIL="${GITHUB_ACTOR}@users.noreply.${GITHUB_DOMAIN:-"github.com"}"
if [ -n "${GITHUB_EMAIL_PREFIX}" ]; then
    USER_EMAIL="${GITHUB_EMAIL_PREFIX}+${USER_EMAIL}"
fi

# set the GitHub configuration for using GitHub cli.
git config --global user.name "${GITHUB_ACTOR}" >/dev/null
git config --global user.email "${USER_EMAIL}" >/dev/null

mkdir -p $REPO_ROOT && cd $REPO_ROOT

# Create a fork of the repository
echo "$SCRIPT_NAME][INFO] forking and cloning $GITHUB_ORG/$SERVICE_REPO... "
if ! gh repo fork "$GITHUB_ORG/$SERVICE_REPO" --clone=true >/dev/null; then
echo ""
echo "$SCRIPT_NAME][ERROR] failed to fork and clone $GITHUB_ORG/$SERVICE_REPO. Exiting "
exit 1
fi
echo "ok"

# `gh repo fork` reuses a pre-existing bot fork without syncing it, so the clone
# can be stale — pinning older runtime/code-generator deps than upstream. Re-base
# the working tree on the CURRENT source main so the generated code matches the
# controller's up-to-date dependency pins. Otherwise code-generator@main emits
# calls to runtime APIs the stale fork's go.mod predates and the controller will
# not compile (a mismatch that affects every resource, not the added one).
echo "$SCRIPT_NAME][INFO] Syncing $SERVICE_REPO checkout to current $GITHUB_ORG/$SERVICE_REPO main..."
cd "$SERVICE_REPO_DIR"
SOURCE_URL="https://$GITHUB_TOKEN@github.com/$GITHUB_ORG/$SERVICE_REPO.git"
git remote add source "$SOURCE_URL" 2>/dev/null || git remote set-url source "$SOURCE_URL"
if ! git fetch --depth=1 source main >/dev/null 2>&1; then
  echo "$SCRIPT_NAME][ERROR] failed to fetch $GITHUB_ORG/$SERVICE_REPO main. Exiting "
  exit 1
fi
git reset --hard source/main >/dev/null
echo "ok"

cd $WORKFLOW_DIR

# Point the role-based workflow at the forked controller checkout this script
# later commits and pushes, so the Implementer agent edits exactly that tree
# (otherwise the workflow would default CONTROLLER_DIR to the agents package cwd).
export CONTROLLER_DIR="$SERVICE_REPO_DIR"

# code-generator's `make build-controller` defaults the controller source path to
# <code-generator>/../<service>-controller, but the fork lives under a different
# parent ($REPO_ROOT) than the clonerefs-mounted deps. Point it explicitly at the
# forked checkout so code generation writes into the tree this script commits.
export SERVICE_CONTROLLER_SOURCE_PATH="$CONTROLLER_DIR"

# code-generator and ack-dev-skills (the role SOPs/schemas) are delivered to this
# pod as Prow extra_refs cloned by the clonerefs init container. The agent-plugin
# sets CODEGEN_DIR / ACK_DEV_SKILLS_DIR explicitly; default to the standard
# clonerefs paths here so a manual/local run still resolves them.
export CODEGEN_DIR="${CODEGEN_DIR:-/home/$JOB_USER/go/src/github.com/aws-controllers-k8s/code-generator}"
export ACK_DEV_SKILLS_DIR="${ACK_DEV_SKILLS_DIR:-/home/$JOB_USER/go/src/github.com/aws-controllers-k8s/ack-dev-skills}"

# Run the workflow command
echo "$SCRIPT_NAME][INFO] Starting workflow"
python -m workflows resource-addition --service $SERVICE --resource $RESOURCE
echo "$SCRIPT_NAME][INFO]Resource addition workflow completed successfully"

cd $SERVICE_REPO_DIR

# Create a new branch
echo "$SCRIPT_NAME][INFO] Creating a new branch..."
git checkout -b $LOCAL_GIT_BRANCH >/dev/null

# Commit changes
echo "$SCRIPT_NAME][INFO] Committing changes..."
git add -A  >/dev/null
COMMIT_MSG="Add $RESOURCE to $SERVICE"
git commit -am "$COMMIT_MSG" >/dev/null

# Push changes to the forked repository
echo "$SCRIPT_NAME][INFO] Pushing changes to the forked repository..."
git push --force "https://$GITHUB_TOKEN@github.com/$GITHUB_ACTOR/$SERVICE_REPO.git" \
   "$LOCAL_GIT_BRANCH:$PR_SOURCE_BRANCH" &>/dev/null

# fetch all remotes to bring changes locally
git fetch --all >/dev/null
# set local branch to track origin(PR source)
git branch "$LOCAL_GIT_BRANCH" --set-upstream-to origin/"$PR_SOURCE_BRANCH" >/dev/null
# sync local branch with the origin, if there is a diff the gh pr command
# prompts for user input
git pull --rebase >/dev/null

echo "$SCRIPT_NAME][INFO] Creating a new pull request for $ORG_REPO , from $PR_SOURCE_BRANCH -> $PR_TARGET_BRANCH branch... "
if ! gh pr create -R "$ORG_REPO" -t "$COMMIT_MSG" -b "ACK Agent changes adding $RESOURCE to $SERVICE-controller" -B "$PR_TARGET_BRANCH" >/dev/null ; then
  echo ""
  echo "gh.sh][ERROR] Failed to create pull request. Exiting... "
  return 1
fi
echo "ok"

