#!/usr/bin/env bash
# mirror one benchmark PR into its per-arm target repos, the way Martian's
# step0_fork_prs.py does (base branch at the upstream PR's base sha, PR head as
# `pr-<n>`), plus one commit on the base branch adding the arm's workflow file.
# SPEC: {"upstream","number","base_ref","base_sha","org","targets":[{"repo","arm"}]}
set -euo pipefail

upstream=$(jq -r .upstream <<<"$SPEC")
number=$(jq -r .number <<<"$SPEC")
base_ref=$(jq -r .base_ref <<<"$SPEC")
base_sha=$(jq -r .base_sha <<<"$SPEC")
org=$(jq -r .org <<<"$SPEC")
arms_dir="$PWD/arms"

git config --global user.name "martian-bench"
git config --global user.email "martian-bench@users.noreply.github.com"
git init -q --bare up.git
cd up.git
git remote add origin "https://github.com/$upstream.git"
git fetch -q --no-tags origin "+refs/pull/$number/head:refs/pr/head" "$base_sha:refs/pr/base"
echo "fetched: $(git count-objects -vH | grep size-pack)"

jq -r '.targets[] | "\(.repo) \(.arm)"' <<<"$SPEC" | while read -r repo arm; do
  file=$(ls "$arms_dir/$arm")
  export GIT_INDEX_FILE="$PWD/index-$arm"
  git read-tree "$base_sha"
  blob=$(git hash-object -w "$arms_dir/$arm/$file")
  git update-index --add --cacheinfo "100644,$blob,.github/workflows/$file"
  tree=$(git write-tree)
  unset GIT_INDEX_FILE
  commit=$(git commit-tree "$tree" -p "$base_sha" -m "Add $file")
  url="https://x-access-token:${PUSH_TOKEN}@github.com/$org/$repo.git"
  start=$(date +%s)
  git push -q "$url" "$commit:refs/heads/$base_ref"
  git push -q "$url" "refs/pr/head:refs/heads/pr-$number"
  echo "pushed $repo ($arm) in $(( $(date +%s) - start ))s"
done
