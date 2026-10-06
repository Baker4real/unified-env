#!/usr/bin/env bash
# Skills sweep: 对账本中每个 GitHub 来源解析 HEAD（分支或固定 tag）并与 last_checked_commit 比较。
# 用法: bash sweep-lsremote.sh <outDir> [prevResults.tsv]
#   outDir 必须已含 gen-ledger-tsv.cjs 生成的 ledger-github-sources.tsv。
#   写入 outDir: lsremote-results.tsv, lsremote-errors.log, tags-check.tmp,
#   以及（给了 prevResults 时）sweep-diff-output.txt。
#   同目录 sweep-exclude.txt 中列出的 repo 键不请求网络，结果行标记 EXCLUDED。
#   代理: 通过环境变量传入（如 HTTPS_PROXY=http://127.0.0.1:17897），脚本不写死。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$1"
PREV="$2"
if [ -z "$OUT" ]; then echo "usage: bash sweep-lsremote.sh <outDir> [prevResults.tsv]" >&2; exit 2; fi
command -v cygpath >/dev/null 2>&1 && { OUT="$(cygpath -u "$OUT")"; [ -n "$PREV" ] && PREV="$(cygpath -u "$PREV")"; }
cd "$OUT" || exit 1
[ -f ledger-github-sources.tsv ] || { echo "missing $OUT/ledger-github-sources.tsv (run gen-ledger-tsv.cjs first)" >&2; exit 1; }
: > lsremote-results.tsv
: > lsremote-errors.log
: > tags-check.tmp

EXCLUDE="$SCRIPT_DIR/sweep-exclude.txt"
is_excluded() { [ -f "$EXCLUDE" ] && grep -v '^[[:space:]]*#' "$EXCLUDE" | tr -d '\r' | grep -Fxq -- "$1"; }

resolve() { # repo pattern -> commit or empty
  git ls-remote "https://github.com/$1" "$2" 2>>lsremote-errors.log | awk '{print $1}' | head -1
}

while IFS=$'\t' read -r repo ref commit status skills; do
  [ -z "$repo" ] && continue
  if is_excluded "$repo"; then
    printf '%s\tEXCLUDED\t\t%s\t%s\n' "$repo" "$ref" "$status" >> lsremote-results.tsv
    continue
  fi
  head="" mode=""
  head=$(resolve "$repo" "refs/heads/$ref"); [ -n "$head" ] && mode="BRANCH"
  if [ -z "$head" ]; then
    head=$(resolve "$repo" "refs/tags/$ref^{}"); [ -n "$head" ] && mode="TAG-DEREF"
  fi
  if [ -z "$head" ]; then
    head=$(resolve "$repo" "refs/tags/$ref"); [ -n "$head" ] && mode="TAG-LIGHT"
  fi
  if [ -z "$head" ]; then
    sleep 2
    head=$(resolve "$repo" "refs/heads/$ref"); [ -n "$head" ] && mode="BRANCH"
    if [ -z "$head" ]; then
      head=$(resolve "$repo" "refs/tags/$ref^{}"); [ -n "$head" ] && mode="TAG-DEREF"
    fi
  fi
  if [ -z "$head" ]; then
    printf '%s\tLSREMOTE-FAILED\t\t%s\t%s\n' "$repo" "$ref" "$status" >> lsremote-results.tsv
    continue
  fi
  if [ "$mode" = "BRANCH" ]; then
    if [ "$head" = "$commit" ]; then
      printf '%s\tSAME\t%s\t%s\t%s\n' "$repo" "$head" "$ref" "$status" >> lsremote-results.tsv
    else
      printf '%s\tCHANGED\t%s\t%s\t%s\n' "$repo" "$head" "$ref" "$status" >> lsremote-results.tsv
    fi
  else
    verdict="TAGPIN"
    [ "$head" != "$commit" ] && verdict="TAGPIN-DRIFT"
    latest_tag=$(git ls-remote --tags "https://github.com/$repo" 2>>lsremote-errors.log \
      | awk '{print $2}' | sed 's|refs/tags/||; s|\^{}$||' | grep -v '^pr-' | sort -Vu | tail -1)
    printf '%s\t%s\t%s\t%s\t%s\tlatest_tag=%s\n' "$repo" "$verdict" "$head" "$ref" "$status" "$latest_tag" >> tags-check.tmp
    printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$verdict" "$head" "$ref" "$status" >> lsremote-results.tsv
  fi
done < ledger-github-sources.tsv

echo "== verdict counts =="
cut -f2 lsremote-results.tsv | sort | uniq -c
echo "== tags (pin vs latest) =="
cat tags-check.tmp

if [ -n "$PREV" ]; then
  echo "== diff vs $PREV =="
  node "$SCRIPT_DIR/sweep-diff.cjs" "$PREV" lsremote-results.tsv | tee sweep-diff-output.txt
fi
