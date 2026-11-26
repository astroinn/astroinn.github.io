#!/bin/bash
set -euo pipefail
umask 022
export GIT_TERMINAL_PROMPT=0

data=/opt/astroinn-blog/data
repo="$data/repo.git"
mkdir -p "$data/releases"
exec 9>"$data/pull.lock"
flock -w 10 9
if [ ! -d "$repo" ]; then
    git init --bare --quiet "$repo"
fi
git --git-dir="$repo" fetch --quiet --depth=1 \
    https://github.com/astroinn/astroinn.github.io.git \
    +refs/heads/server-site:refs/heads/server-site
revision=$(git --git-dir="$repo" rev-parse refs/heads/server-site)
cd "$data"
if [ "$(readlink current || true)" = "releases/$revision" ]; then
    exit 0
fi
# Refuse symlinks and submodules: only regular static files may be extracted.
if git --git-dir="$repo" ls-tree -r "$revision" | awk '$1 != "100644" && $1 != "100755" { found=1 } END { exit !found }'; then
    echo 'Refusing release containing symlinks or submodules.' >&2
    exit 1
fi
stage=$(mktemp -d "$data/releases/.staging-XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
git --git-dir="$repo" archive "$revision" | tar -x -C "$stage" --no-same-owner
test -s "$stage/index.html"
find "$stage" -type d -exec chmod 755 {} +
find "$stage" -type f -exec chmod 644 {} +
if [ ! -d "releases/$revision" ]; then
    mv "$stage" "releases/$revision"
fi
if [ -L current ]; then
    ln -sfn "$(readlink current)" previous.new
    mv -Tf previous.new previous
fi
ln -sfn "releases/$revision" current.new
mv -Tf current.new current
echo "Activated release $revision"
