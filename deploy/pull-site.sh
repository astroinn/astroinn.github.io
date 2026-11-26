#!/bin/bash
set -euo pipefail
umask 022
data=/opt/astroinn-blog/data
mkdir -p "$data/releases"
exec 9>"$data/pull.lock"
flock -w 10 9
repo=astroinn/astroinn.github.io
revision=$(
    curl --fail --silent --show-error --connect-timeout 5 --max-time 12 \
        "https://api.github.com/repos/$repo/git/ref/heads/server-site" |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["object"]["sha"])'
)
[[ "$revision" =~ ^[a-f0-9]{40}$ ]]
cd "$data"
if [ "$(readlink current || true)" = "releases/$revision" ]; then
    exit 0
fi
stage=$(mktemp -d "$data/releases/.staging-XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
if [ ! -d "releases/$revision" ]; then
    curl --fail --silent --show-error --connect-timeout 5 --max-time 28 \
        --output "$stage/site.tar.gz" "https://codeload.github.com/$repo/tar.gz/$revision"
    python3 - "$stage" <<'PY'
import sys
import tarfile
from pathlib import Path, PurePosixPath
from shutil import copyfileobj

stage = Path(sys.argv[1])
destination = stage / "files"
destination.mkdir()
with tarfile.open(stage / "site.tar.gz", "r:gz") as archive:
    for member in archive:
        path = PurePosixPath(member.name)
        if (path.is_absolute() or ".." in path.parts or
                not (member.isdir() or member.isfile())):
            raise SystemExit(f"Invalid archive entry: {member.name}")
        relative = path.parts[1:]
        if not relative:
            if member.isdir():
                continue
            raise SystemExit("Unexpected file at archive root")
        target = destination.joinpath(*relative)
        if member.isdir():
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(member) as contents, target.open("xb") as output:
                copyfileobj(contents, output)
PY
    test -s "$stage/files/index.html"
    mv "$stage/files" "releases/$revision"
fi
test -s "releases/$revision/index.html"
if [ -L current ]; then
    ln -sfn "$(readlink current)" previous.new
    mv -Tf previous.new previous
fi
ln -sfn "releases/$revision" current.new
mv -Tf current.new current
echo "Activated release $revision"
