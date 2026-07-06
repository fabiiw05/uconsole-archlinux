#!/usr/bin/env bash
# 共通ヘルパー: ログ出力・依存チェック・クリーンアップ管理
# build.sh から source して使用する。

# --- ログ --------------------------------------------------------------
_c_reset=$'\e[0m'; _c_blue=$'\e[34m'; _c_green=$'\e[32m'
_c_yellow=$'\e[33m'; _c_red=$'\e[31m'

log()  { printf '%s==>%s %s\n' "$_c_blue"   "$_c_reset" "$*"; }
ok()   { printf '%s==>%s %s\n' "$_c_green"  "$_c_reset" "$*"; }
warn() { printf '%s==>%s %s\n' "$_c_yellow" "$_c_reset" "$*" >&2; }
die()  { printf '%s==> error:%s %s\n' "$_c_red" "$_c_reset" "$*" >&2; exit 1; }

# --- 前提チェック ------------------------------------------------------
require_root() {
  [[ ${EUID} -eq 0 ]] || die "root で実行してください (sudo ./build.sh)"
}

require_cmds() {
  local missing=()
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]})); then
    die "必要なコマンドがありません: ${missing[*]}"
  fi
}

# --- クリーンアップ管理 ------------------------------------------------
# 逆順で実行するクリーンアップスタック。
_cleanup_stack=()
push_cleanup() { _cleanup_stack+=("$1"); }

run_cleanup() {
  local i
  for (( i=${#_cleanup_stack[@]}-1; i>=0; i-- )); do
    eval "${_cleanup_stack[i]}" || warn "cleanup 失敗: ${_cleanup_stack[i]}"
  done
  _cleanup_stack=()
}

# EXIT トラップで確実に後始末する。
trap 'run_cleanup' EXIT
