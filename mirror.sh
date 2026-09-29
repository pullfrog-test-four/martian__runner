#!/usr/bin/env bash
# mirror one benchmark PR into its per-arm target repos, the way Martian's
# step0_fork_prs.py does (base branch at the upstream PR's base sha, PR head as
# `pr-<n>`), with two commits on the base branch:
#   1. drop upstream `.github/workflows/*` and the Dependabot config, so neither
#      upstream CI nor Dependabot fires in the mirror (no benchmark PR touches `.github/`)
#   2. add the arm's workflow file, in its own small push so GitHub registers it —
#      a huge initial push can skip workflow registration entirely (seen on sentry)
# the PR diff is merge-base...head, so neither commit is part of what gets reviewed.
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
git init -q up
cd up
git remote add origin "https://github.com/$upstream.git"
git fetch -q --no-tags origin "+refs/pull/$number/head:refs/pr/head" "$base_sha:refs/pr/base"
echo "fetched: $(git count-objects -vH | grep size-pack)"

export GIT_INDEX_FILE="$PWD/index"
git read-tree "$base_sha"
git ls-tree -r -z --name-only "$base_sha" -- .github/workflows .github/dependabot.yml .github/dependabot.yaml |
  xargs -0 -r git update-index --force-remove --
stripped=$(git commit-tree "$(git write-tree)" -p "$base_sha" -m "Drop upstream CI and Dependabot config (benchmark mirror)")
unset GIT_INDEX_FILE

jq -r '.targets[] | "\(.repo) \(.arm)"' <<<"$SPEC" | while read -r repo arm; do
  file=$(ls "$arms_dir/$arm")
  export GIT_INDEX_FILE="$PWD/index-$arm"
  git read-tree "$stripped"
  blob=$(git hash-object -w "$arms_dir/$arm/$file")
  git update-index --add --cacheinfo "100644,$blob,.github/workflows/$file"
  tree=$(git write-tree)
  unset GIT_INDEX_FILE
  commit=$(git commit-tree "$tree" -p "$stripped" -m "Add $file")
  url="https://x-access-token:${PUSH_TOKEN}@github.com/$org/$repo.git"
  start=$(date +%s)
  git push -q "$url" "$stripped:refs/heads/$base_ref"
  git push -q "$url" "refs/pr/head:refs/heads/pr-$number"
  git push -q "$url" "$commit:refs/heads/$base_ref"
  echo "pushed $repo ($arm) in $(( $(date +%s) - start ))s"
done
