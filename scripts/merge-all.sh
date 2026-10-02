#!/usr/bin/env bash
# merge-all.sh — merge một nhánh phase vào base branch ở MỌI repo có nhánh đó (GIT WORKFLOW CONTRACT mục 8).
# Chỉ chạy SAU KHI người review xác nhận phase xong (M-20, M-25). Không bao giờ đụng main, không force-push,
# không xoá nhánh, không tự giải quyết conflict.
#
# Cách dùng (trong learning-engine-infra):  make merge BRANCH=phase/MAIN-FND-01-technical-foundation
# Tuỳ chọn:  BASE=develop (mặc định)  PUSH=0 (không push)  SKIP_GATE=1 (bỏ gate — chỉ khi người dùng yêu cầu rõ)
#
# Các bước: 1) preflight (repo sạch, fetch, fast-forward base) → 2) kiểm conflict ở mọi repo bằng git merge-tree
# → 3) merge --no-ff vào base cục bộ + chạy gate từng repo → 4) gate lỗi: trả base cục bộ của mọi repo về origin
# → 5) gate đạt: push base (không --force), trả mỗi repo về nhánh đang đứng lúc đầu.

set -u

# ---- Cấu hình: thứ tự repo (producer → consumer → blueprint → hạ tầng) và gate từng repo ----
REPOS=(learning-engine-backend learning-engine-web learning-engine-docs learning-engine-infra)

BASE="${BASE:-develop}"
PUSH="${PUSH:-1}"
SKIP_GATE="${SKIP_GATE:-0}"
BRANCH="${BRANCH:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WS_DIR="$(cd "$INFRA_DIR/.." && pwd)"

say() { printf '%s\n' "$*"; }
err() { printf 'LỖI: %s\n' "$*" >&2; }

repo_dir() { printf '%s/%s' "$WS_DIR" "$1"; }

if [ -z "$BRANCH" ]; then
  BRANCH="$(git -C "$(repo_dir learning-engine-docs)" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  say "BRANCH không được truyền — dùng nhánh đang đứng của learning-engine-docs: '${BRANCH}' (agent luôn phải truyền BRANCH rõ ràng)."
fi
case "$BRANCH" in
  ""|main|master|"$BASE") err "BRANCH='$BRANCH' không hợp lệ (không merge base/main vào chính nó)."; exit 2 ;;
esac
PHASE_ID="$(printf '%s' "$BRANCH" | sed -n 's#^[a-z]*/\([A-Z0-9]*-[A-Z]*-[0-9][0-9]*[a-z]*\).*#\1#p')"
[ -n "$PHASE_ID" ] || PHASE_ID="$BRANCH"

# ---- Gate của từng repo: chỉ chạy lệnh thực có, lệnh chưa có thì bỏ qua (không báo lỗi) ----
make_has() { make -C "$1" -n "$2" >/dev/null 2>&1; }
pkg_has() { [ -f "$1/package.json" ] && python3 -c "import json,sys;sys.exit(0 if '$2' in json.load(open('$1/package.json')).get('scripts',{}) else 1)"; }

run_gate() {
  local repo="$1" dir; dir="$(repo_dir "$repo")"
  case "$repo" in
    learning-engine-backend)
      for t in lint test build migrate-validate; do
        if [ -f "$dir/Makefile" ] && make_has "$dir" "$t"; then say "  gate $repo: make $t"; make -C "$dir" "$t" || return 1; fi
      done ;;
    learning-engine-web)
      if [ -f "$dir/pnpm-lock.yaml" ]; then say "  gate $repo: pnpm install --frozen-lockfile"; (cd "$dir" && pnpm install --frozen-lockfile) || return 1; fi
      for s in lint typecheck test build; do
        if pkg_has "$dir" "$s"; then say "  gate $repo: pnpm run $s"; (cd "$dir" && pnpm run "$s") || return 1; fi
      done ;;
    learning-engine-docs)
      if [ -f "$dir/phase-tracking.html" ]; then
        say "  gate $repo: parse JSON phase-data"
        (cd "$dir" && python3 -c "import re,json;t=open('phase-tracking.html',encoding='utf-8').read();json.loads(re.search(r'<script id=\"phase-data\" type=\"application/json\">(.*?)</script>',t,re.S).group(1));print('  phase-data OK')") || return 1
      fi ;;
    learning-engine-infra)
      if command -v docker >/dev/null 2>&1; then say "  gate $repo: docker compose config"; (cd "$dir" && docker compose config -q) || return 1; fi
      bash -n "$dir/scripts/merge-all.sh" || return 1 ;;
  esac
  return 0
}

# ---- Bước 0: chọn repo có nhánh ----
declare -a TARGETS=() REFS=() ORIG=() BASEREF=() PRE=()
FETCH_FAILED=0
for repo in "${REPOS[@]}"; do
  dir="$(repo_dir "$repo")"
  if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    err "thiếu repo $repo tại $dir (chạy 'make check-repos')."; exit 2
  fi
  if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    if ! git -C "$dir" fetch --quiet origin 2>/dev/null; then
      FETCH_FAILED=1
      say "Cảnh báo: không fetch được origin của $repo (thiếu quyền/credential? xem docs/29-environment-setup.md)."
    fi
  fi
  ref=""
  if git -C "$dir" show-ref --verify --quiet "refs/heads/$BRANCH"; then ref="$BRANCH"
  elif git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then ref="origin/$BRANCH"; fi
  if [ -z "$ref" ]; then say "- $repo: không có nhánh $BRANCH → bỏ qua."; continue; fi
  if git -C "$dir" show-ref --verify --quiet "refs/heads/$BASE" && git -C "$dir" merge-base --is-ancestor "$ref" "$BASE" 2>/dev/null; then
    say "- $repo: $BRANCH đã nằm trong $BASE → bỏ qua."; continue
  fi
  TARGETS+=("$repo"); REFS+=("$ref")
done

if [ "${#TARGETS[@]}" -eq 0 ]; then
  say "Không repo nào cần merge nhánh $BRANCH. Không thay đổi gì."
  exit 0
fi
if [ "$FETCH_FAILED" -eq 1 ] && [ "$PUSH" = "1" ]; then
  err "fetch thất bại ở ít nhất một repo; không merge khi không đồng bộ được origin. Cấp quyền git rồi chạy lại (hoặc PUSH=0 khi người dùng yêu cầu)."
  exit 3
fi
say "Phase $PHASE_ID — merge $BRANCH vào $BASE ở: ${TARGETS[*]}"

# ---- Bước 1: preflight ----
for i in "${!TARGETS[@]}"; do
  repo="${TARGETS[$i]}"; dir="$(repo_dir "$repo")"
  if [ -n "$(git -C "$dir" status --porcelain)" ]; then err "$repo có thay đổi chưa commit — dừng, không repo nào bị merge."; exit 4; fi
  ORIG[$i]="$(git -C "$dir" symbolic-ref --quiet --short HEAD || git -C "$dir" rev-parse HEAD)"
  if ! git -C "$dir" show-ref --verify --quiet "refs/heads/$BASE"; then
    if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$BASE"; then
      git -C "$dir" branch --quiet "$BASE" "origin/$BASE"
    else
      err "$repo chưa có nhánh $BASE (người vận hành tạo trước MAIN-FND-01, xem docs/25-git-workflow.md)."; exit 4
    fi
  fi
  BASEREF[$i]="$BASE"
  if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$BASE"; then
    if git -C "$dir" merge-base --is-ancestor "$BASE" "origin/$BASE"; then
      BASEREF[$i]="origin/$BASE"   # base cục bộ sẽ được fast-forward lên origin ở bước 3
    elif ! git -C "$dir" merge-base --is-ancestor "origin/$BASE" "$BASE"; then
      err "$repo: $BASE cục bộ và origin/$BASE đã tách nhau, không fast-forward được — dừng."; exit 4
    fi
  fi
done

# ---- Bước 2: kiểm conflict ở MỌI repo trước khi merge repo nào ----
CONFLICT=0
for i in "${!TARGETS[@]}"; do
  repo="${TARGETS[$i]}"; dir="$(repo_dir "$repo")"; ref="${REFS[$i]}"
  out="$(git -C "$dir" merge-tree --write-tree --name-only "${BASEREF[$i]}" "$ref" 2>&1)"; rc=$?
  if [ $rc -ne 0 ]; then
    CONFLICT=1
    say "CONFLICT ở $repo (nhánh $ref vào $BASE). File:"
    printf '%s\n' "$out" | sed -n '2,/^$/p' | sed 's/^/    /'
  fi
done
if [ "$CONFLICT" -eq 1 ]; then
  err "có conflict — không repo nào bị merge. Hướng xử lý do người chọn (merge $BASE vào nhánh phase rồi sửa trong path của track, hoặc người tự giải quyết)."
  exit 5
fi

# ---- Bước 3: merge --no-ff + gate ----
MERGED=()
rollback() {
  for j in "${MERGED[@]}"; do
    r="${TARGETS[$j]}"; d="$(repo_dir "$r")"
    git -C "$d" reset --quiet --hard "${PRE[$j]}"
    git -C "$d" checkout --quiet "${ORIG[$j]}" 2>/dev/null || true
    say "  đã trả $BASE cục bộ của $r về trạng thái trước merge."
  done
}
for i in "${!TARGETS[@]}"; do
  repo="${TARGETS[$i]}"; dir="$(repo_dir "$repo")"; ref="${REFS[$i]}"
  git -C "$dir" checkout --quiet "$BASE" || { err "không checkout được $BASE ở $repo"; rollback; exit 6; }
  if [ "${BASEREF[$i]}" != "$BASE" ]; then
    git -C "$dir" merge --ff-only --quiet "${BASEREF[$i]}" || { err "không fast-forward được $BASE ở $repo"; git -C "$dir" checkout --quiet "${ORIG[$i]}"; rollback; exit 6; }
  fi
  PRE[$i]="$(git -C "$dir" rev-parse HEAD)"
  MERGED+=("$i")
  if ! git -C "$dir" merge --no-ff --quiet -m "Merge $BRANCH into $BASE [$PHASE_ID]" "$ref"; then
    err "merge thất bại ở $repo"; git -C "$dir" merge --abort 2>/dev/null; rollback; exit 6
  fi
  say "- $repo: đã merge cục bộ ($(git -C "$dir" rev-parse --short HEAD))."
  if [ "$SKIP_GATE" != "1" ]; then
    if ! run_gate "$repo"; then err "gate FAILED ở $repo — không push repo nào."; rollback; exit 7; fi
  else
    say "  SKIP_GATE=1: bỏ gate theo yêu cầu người dùng."
  fi
done

# ---- Bước 4: push + trả về nhánh ban đầu ----
PUSH_FAIL=0
for i in "${!TARGETS[@]}"; do
  repo="${TARGETS[$i]}"; dir="$(repo_dir "$repo")"
  if [ "$PUSH" = "1" ]; then
    if git -C "$dir" push --quiet origin "$BASE"; then say "- $repo: đã push $BASE ($(git -C "$dir" rev-parse --short "$BASE"))."
    else PUSH_FAIL=1; err "$repo: push bị từ chối — merge vẫn giữ ở cục bộ. Kiểm branch protection/quyền (docs/25, docs/29)."; fi
  else
    say "- $repo: PUSH=0, giữ merge ở cục bộ ($(git -C "$dir" rev-parse --short "$BASE"))."
  fi
  git -C "$dir" checkout --quiet "${ORIG[$i]}" 2>/dev/null || true
done
say "Kết quả: repo → merge commit đã in ở trên. Bước tiếp theo: đánh DONE theo M-26 (docs/contracts/manual-execution.md)."
[ "$PUSH_FAIL" -eq 0 ] || exit 8
exit 0
