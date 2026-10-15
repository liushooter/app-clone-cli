#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  printf '%s\n' 'Usage: ./republish.sh [v0.2.0]' \
    'Republish HEAD, wait for both architectures, and preserve existing Release information.'
  exit 0
fi
fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
[[ $# -le 1 ]] || fail '只接受一个版本标签。'
for tool in git gh shasum; do
  command -v "$tool" >/dev/null || fail "缺少命令：$tool"
done
version=$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' sources/core/version.swift)
tag="${1:-v$version}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9a-z]+(\.[0-9a-z]+)*)?$ ]] || fail '版本标签格式无效。'
[[ "$tag" == "v$version" ]] || fail "标签必须与源码版本 v$version 一致。"
[[ -z "$(git status --porcelain)" ]] || fail '请先提交工作区修改。'
head=$(git rev-parse HEAD)
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/app-clone-republish.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
fields=name,body,isDraft,isPrerelease,targetCommitish,url
gh release view "$tag" --repo "$repo" --json "$fields" > "$scratch/before.json"
remote_refs=$(git ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}")
old=$(printf '%s\n' "$remote_refs" | awk -v ref="refs/tags/$tag" '$2 == ref {print $1}')
peeled=$(printf '%s\n' "$remote_refs" | awk -v ref="refs/tags/$tag^{}" '$2 == ref {print $1}')
[[ -n "$old" ]] || fail '远端标签不存在；本脚本仅用于重新发布已有版本。'

find_run() {
  gh run list --repo "$repo" --workflow release.yml --branch "$tag" \
    --event push --commit "$head" --limit 1 --json databaseId --jq '.[0].databaseId // empty'
}
if [[ "${peeled:-$old}" == "$head" ]]; then
  run=$(find_run)
  [[ -n "$run" ]] || fail '当前标签没有对应的发布流水线，请检查 Actions。'
  status=$(gh run view "$run" --repo "$repo" --json status --jq .status)
  if [[ "$status" == completed ]]; then
    gh run rerun "$run" --repo "$repo"
  fi
else
  # Only replace the tag we inspected; never overwrite a concurrent tag update.
  git push origin "HEAD:refs/tags/$tag" "--force-with-lease=refs/tags/$tag:$old"
  run=''
  for ((attempt=0; attempt<60; attempt++)); do
    run=$(find_run)
    [[ -z "$run" ]] || break
    sleep 2
  done
  [[ -n "$run" ]] || fail '未找到发布流水线，请检查 GitHub Actions 后重试。'
fi
printf '正在发布 %s (%s)：https://github.com/%s/actions/runs/%s\n' "$tag" "$head" "$repo" "$run"
gh run watch "$run" --repo "$repo" --interval 10 --exit-status
gh release view "$tag" --repo "$repo" --json "$fields" > "$scratch/after.json"
cmp -s "$scratch/before.json" "$scratch/after.json" || fail 'Release 信息发生变化，请检查；脚本没有修改其信息。'
gh release download "$tag" --repo "$repo" --dir "$scratch" \
  --pattern "app-clone-$tag-macos-apple-silicon.tar.gz" \
  --pattern "app-clone-$tag-macos-intel.tar.gz" --pattern sha256sums.txt
for chip in apple-silicon intel; do
  [[ -s "$scratch/app-clone-$tag-macos-$chip.tar.gz" ]] || fail "缺少 $chip 发布包。"
done
(cd "$scratch" && shasum -a 256 --check sha256sums.txt)
printf '发布完成，Release 信息保持不变：https://github.com/%s/releases/tag/%s\n' "$repo" "$tag"
