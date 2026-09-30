#!/usr/bin/env bash
# mirror one benchmark PR into its per-arm target repos, the way Martian's
# step0_fork_prs.py does (base branch at the upstream PR's base sha, PR head as
# `pr-<n>`), with two commits on the base branch:
#   1. drop upstream `.github/workflows/*` and the Dependabot config, so neither
#      upstream CI nor Dependabot fires in the mirror (no benchmark PR touches `.github/`)
#   2. add the arm's workflow file, in its own small push so GitHub registers it —
#      a huge initial push can skip workflow registration entirely (seen on sentry)
# the PR diff is merge-base...head, so neither commit is part of what gets reviewed.
# `from_merge_base` starts the base branch at merge-base(base_sha, head) instead: the diff is
# identical, but a PR that conflicts with its upstream base becomes mergeable, and GitHub
# creates no `pull_request` runs for a conflicting PR.
# a target with an `action_ref` is a prompt variant: its workflow is arms/pullfrog-src with that ref.
# SPEC: {"upstream","number","base_ref","base_sha","org","from_merge_base"?,"targets":[{"repo","arm","action_ref"?}]}
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
if [ "$(jq -r '.from_merge_base // false' <<<"$SPEC")" = true ]; then
  base_sha=$(git merge-base refs/pr/base refs/pr/head)
  echo "base from merge-base: $base_sha"
fi

export GIT_INDEX_FILE="$PWD/index"
git read-tree "$base_sha"
git ls-tree -r -z --name-only "$base_sha" -- .github/workflows .github/dependabot.yml .github/dependabot.yaml |
  xargs -0 -r git update-index --force-remove --
stripped=$(git commit-tree "$(git write-tree)" -p "$base_sha" -m "Drop upstream CI and Dependabot config (benchmark mirror)")
unset GIT_INDEX_FILE

# GitHub now and then answers a push with a bare "remote rejected (failed)"; forcing makes a retry,
# and re-staging a batch whose mirror failed part-way, overwrite whatever was left behind
push() {
  for _ in 1 2 3; do git push -qf "$@" && return; sleep 10; done
  return 1
}

jq -r '.targets[] | "\(.repo) \(.arm) \(.action_ref // "")"' <<<"$SPEC" | while read -r repo arm ref; do
  if [ -n "$ref" ]; then
    file=pullfrog.yml
    sed "s|__ACTION_REF__|$ref|" "$arms_dir/pullfrog-src/$file" >"$PWD/workflow"
  else
    file=$(ls "$arms_dir/$arm")
    cp "$arms_dir/$arm/$file" "$PWD/workflow"
  fi
  export GIT_INDEX_FILE="$PWD/index-$arm"
  git read-tree "$stripped"
  blob=$(git hash-object -w "$PWD/workflow")
  git update-index --add --cacheinfo "100644,$blob,.github/workflows/$file"
  tree=$(git write-tree)
  unset GIT_INDEX_FILE
  commit=$(git commit-tree "$tree" -p "$stripped" -m "Add $file")
  url="https://x-access-token:${PUSH_TOKEN}@github.com/$org/$repo.git"
  start=$(date +%s)
  push "$url" "$stripped:refs/heads/$base_ref"
  push "$url" "refs/pr/head:refs/heads/pr-$number"
  push "$url" "$commit:refs/heads/$base_ref"
  echo "pushed $repo ($arm) in $(( $(date +%s) - start ))s"
done
