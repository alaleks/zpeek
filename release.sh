#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

usage() {
    cat <<'EOF'
Usage: ./release.sh [major|minor|patch] [--yes] [--skip-checks]

Create and push a signed version tag from main or master.
The tag starts the GitHub Actions release build.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

bump=patch
yes=false
skip_checks=false
while (($#)); do
    case "$1" in
        major|minor|patch) bump="$1" ;;
        -y|--yes) yes=true ;;
        --skip-checks) skip_checks=true ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
done

command -v git >/dev/null || die 'git is required'
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die 'not a git repository'
[[ -z "$(git status --porcelain)" ]] || die 'commit or stash all changes before releasing'

branch="$(git symbolic-ref --short HEAD)" || die 'HEAD is detached'
[[ "$branch" == main || "$branch" == master ]] || die "release from main or master (current: $branch)"
git remote get-url origin >/dev/null 2>&1 || die 'origin is not configured'
git fetch --tags origin || die 'could not fetch origin'
remote_head="$(git rev-parse --verify "refs/remotes/origin/$branch")" || die "origin/$branch is missing"
[[ "$(git rev-parse HEAD)" == "$remote_head" ]] || die "push or update $branch before releasing"

[[ -n "$(git config --get user.email || true)" ]] || die 'git user.email is not configured'
[[ -n "$(git config --get user.signingkey || true)" ]] || die 'git user.signingkey is not configured'

last_tag=''
while IFS= read -r tag; do
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    git merge-base --is-ancestor "$tag" HEAD || continue
    last_tag="$tag"
    break
done < <(git tag --list 'v*' --sort=-v:refname)

version="${last_tag#v}"
if [[ -z "$last_tag" ]]; then
    version=0.0.0
    range=HEAD
else
    range="$last_tag..HEAD"
fi
[[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "invalid version: $version"
major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"
commits="$(git log "$range" --pretty=format:'- %h %s')"
[[ -n "$commits" ]] || die "no commits since ${last_tag:-v0.0.0}"

case "$bump" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
esac
new_tag="v${major}.${minor}.${patch}"
if git show-ref --verify --quiet "refs/tags/$new_tag"; then
    die "$new_tag already exists"
fi

if [[ "$skip_checks" == false ]]; then
    command -v zig >/dev/null || die 'zig is required (or pass --skip-checks)'
    zig build test || die 'tests failed'
    zig build -Doptimize=ReleaseSafe -Dversion="$new_tag" || die 'release build failed'
    [[ "$(zig-out/bin/zpeek --version)" == "zpeek $new_tag" ]] || die 'built binary has the wrong version'
fi

printf '\n%s -> %s (%s, %s)\n%s\n\n' "${last_tag:-v0.0.0}" "$new_tag" "$bump" "$branch" "$commits"
if [[ "$yes" == false ]]; then
    [[ -t 0 ]] || die 'pass --yes when running without a terminal'
    read -r -p "Create and push signed tag $new_tag? [y/N] " answer
    case "$answer" in
        y|Y|yes|YES|Yes) ;;
        *) printf 'Aborted.\n'; exit 0 ;;
    esac
fi

git tag -s "$new_tag" -m "$new_tag

Changes:
$commits" || die "could not sign $new_tag"
if ! git tag -v "$new_tag" >/dev/null 2>&1; then
    git tag -d "$new_tag" >/dev/null
    die "signature verification failed for $new_tag"
fi
git push origin "refs/tags/$new_tag" || die "push failed; $new_tag remains locally"
printf 'Released %s; GitHub Actions will build the archives.\n' "$new_tag"
