#!/usr/bin/env bash
# DESC: publish this checkout's T3Vision and deploy it to the Vision Pro.
#
#   apps/vision/publish.sh [--logs] [--force] [--dry-run]
#
# THIS BOX CANNOT BUILD APPLE CODE, and T3Vision is not a repo the Mac can build
# directly — it is xcodegen source inside this monorepo. Two indirections have to
# happen before a headset sees anything, and doing them by hand (or asking an agent
# to re-derive them) is why a deploy has been taking minutes of guesswork:
#
#   this checkout ──push──► github.com/eurobob/t3code            (the submodule source)
#                             │
#   t3vision-deploy.git ──────┴─ bumps its `t3code` submodule pointer, commits, pushes
#     (a 3-file wrapper: .gitmodules + project.yml + the submodule)
#                             │
#   mac-verify ───────────────┴─► Mesa queue ──► Mac: xcodegen, build, install, launch
#
# The wrapper exists because project.yml refers to sources across the monorepo
# (apps/vision/Sources, apps/swift-ios/Core, .../App/Cloud, …). The Mac clones the
# wrapper + submodule and runs xcodegen itself — mesa-deploy opts into that whenever
# a repo ships project.yml and no .xcodeproj. So nothing here generates a project,
# and nothing here needs Xcode.
#
# The non-obvious step, and the one that gets done wrong: deploying your work means
# moving the SUBMODULE POINTER to your commit. Pushing your branch is not enough —
# the wrapper still points at whatever it pointed at before, and the Mac faithfully
# builds that. A "deploy" that changes nothing on the headset is this bug.
set -euo pipefail

SUBMODULE_BRANCH="t3code/visionos-swift-client"   # .gitmodules pins the submodule to this
WRAPPER_URL="/home/t3/git/t3vision-deploy.git"    # private bare repo; mac-verify rewrites to ssh://
WRAPPER_DIR="${T3VISION_WRAPPER_DIR:-$HOME/.t3/vision-deploy}"
SCHEME="T3Vision"

LOGS=0; FORCE=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --logs)    LOGS=1; shift;;
    --force)   FORCE=1; shift;;
    --dry-run) DRY=1; shift;;
    -h|--help) sed -n '2,6p' "$0"; exit 0;;
    *) echo "unknown flag: $1" >&2; exit 2;;
  esac
done

say() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

ROOT="$(git rev-parse --show-toplevel)" || die "not inside a git repo"
cd "$ROOT"

# Uncommitted work is invisible to every step below: the Mac fetches from GitHub, not
# from this disk. Silently deploying the last commit while the developer watches their
# unsaved change not take effect is the most expensive failure this script can have.
if [ -n "$(git status --porcelain)" ]; then
  if [ "$FORCE" = "1" ]; then
    say "WARNING: uncommitted changes — deploying HEAD, which does NOT include them"
  else
    git status --short >&2
    die "uncommitted changes. Commit them first (they cannot reach the Mac otherwise), or pass --force to deploy HEAD anyway."
  fi
fi

SHA="$(git rev-parse HEAD)"
say "deploying ${SHA:0:8} from $(git branch --show-current 2>/dev/null || echo 'detached HEAD')"

if [ "$DRY" = "1" ]; then
  say "dry run — would push HEAD to origin/$SUBMODULE_BRANCH, bump the wrapper, then mac-verify"
  exit 0
fi

# 1. The submodule resolves from GitHub, so the commit has to exist there. Push HEAD onto
#    the branch .gitmodules names. A worktree agent is on its own branch; that is fine —
#    what gets deployed is this commit, whatever branch produced it.
say "pushing HEAD -> origin/$SUBMODULE_BRANCH"
git push --force-with-lease origin "HEAD:refs/heads/$SUBMODULE_BRANCH"

# 2. A working clone of the wrapper, created on demand. Kept outside the repo so it
#    survives worktree churn and is shared by every thread.
if [ ! -d "$WRAPPER_DIR/.git" ]; then
  say "cloning the deploy wrapper into $WRAPPER_DIR"
  git clone --quiet "$WRAPPER_URL" "$WRAPPER_DIR"
fi
cd "$WRAPPER_DIR"
git fetch --quiet origin
git checkout --quiet main
git reset --hard --quiet origin/main      # the wrapper holds no local work; it is a pointer

# 3. Move the pointer. --init because a fresh clone has an empty submodule dir.
git submodule update --quiet --init t3code
git -C t3code fetch --quiet origin "$SUBMODULE_BRANCH"
git -C t3code checkout --quiet "$SHA"

if git diff --quiet -- t3code; then
  say "wrapper already points at ${SHA:0:8} — nothing to publish"
else
  git add t3code
  git commit --quiet -m "chore: deploy ${SHA:0:8}"
  git push --quiet origin main
  say "wrapper bumped to ${SHA:0:8} and pushed"
fi

# 4. Hand off to the Mac. Run from the wrapper so mac-verify picks up ITS origin (the
#    private bare repo) rather than this monorepo's.
say "handing off to the Mac build bridge"
# This IS the human act mac-verify gates on: the deploy button, or a person running this
# script deliberately. Agents calling mac-verify --deploy directly are refused and told to
# ask instead, because a deploy launches on a headset someone may be wearing.
export MESA_ALLOW_DEPLOY=1
ARGS=(--scheme "$SCHEME" --deploy)
[ "$LOGS" = "1" ] && ARGS+=(--logs)
exec mac-verify "${ARGS[@]}"
