#!/usr/bin/env bash
# Shared helpers: logging, dependency checks, cleanup management.
# Sourced by build.sh and scripts/*.sh.

# --- Logging -----------------------------------------------------------
_c_reset=$'\e[0m'; _c_blue=$'\e[34m'; _c_green=$'\e[32m'
_c_yellow=$'\e[33m'; _c_red=$'\e[31m'

log()  { printf '%s==>%s %s\n' "$_c_blue"   "$_c_reset" "$*"; }
ok()   { printf '%s==>%s %s\n' "$_c_green"  "$_c_reset" "$*"; }
warn() { printf '%s==>%s %s\n' "$_c_yellow" "$_c_reset" "$*" >&2; }
die()  { printf '%s==> error:%s %s\n' "$_c_red" "$_c_reset" "$*" >&2; exit 1; }

# --- Prerequisite checks -----------------------------------------------
require_root() {
  [[ ${EUID} -eq 0 ]] || die "must run as root (sudo ./build.sh)"
}

require_cmds() {
  local missing=()
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]})); then
    die "missing required commands: ${missing[*]}"
  fi
}

# --- Cleanup management ------------------------------------------------
# Cleanup stack, run in reverse (LIFO) order.
_cleanup_stack=()
push_cleanup() { _cleanup_stack+=("$1"); }

run_cleanup() {
  local i
  for (( i=${#_cleanup_stack[@]}-1; i>=0; i-- )); do
    eval "${_cleanup_stack[i]}" || warn "cleanup failed: ${_cleanup_stack[i]}"
  done
  _cleanup_stack=()
}

# Ensure cleanup runs via an EXIT trap.
trap 'run_cleanup' EXIT

# --- Kernel artifact installation --------------------------------------
# Deploy the self-built kernel artifacts (kernel8.img / dtb / overlays /
# modules) produced by scripts/build-kernel.sh into a target root.
#
#   install_kernel_artifacts <out_dir> <modules_dir> <dest_root>
#
#   <out_dir>     : dir with kernel8.img, *.dtb, overlays/*.dtbo, kver.txt
#                   (build.sh's kernel/out, or the out/ inside a release tarball)
#   <modules_dir> : dir containing lib/modules/<kver> (kernel/modules, or the
#                   modules/ inside a release tarball)
#   <dest_root>   : target root. "" = the live "/" (used by scripts/update.sh);
#                   a mountpoint like work/root (used by build.sh's install_kernel).
#
# Shared by build.sh (into the image being built) and scripts/update.sh (into a
# live, already-running system) so the two paths cannot drift apart.
install_kernel_artifacts() {
  local out_dir="$1" modules_dir="$2" dest_root="$3"

  if [[ ! -f "${out_dir}/kernel8.img" ]]; then
    die "self-built kernel missing (${out_dir}/kernel8.img required)"
  fi
  local kver; kver="$(cat "${out_dir}/kver.txt" 2>/dev/null || true)"
  [[ -n "${kver}" ]] || die "cannot read kver.txt (incomplete build/tarball)"
  log "installing self-built kernel (kver=${kver})"

  # Kernel image (matches kernel=kernel8-cm4.img in config.txt).
  mkdir -p "${dest_root}/boot"
  install -m 0644 "${out_dir}/kernel8.img" "${dest_root}/boot/kernel8-cm4.img"

  shopt -s nullglob
  # dtb
  local dtbs=("${out_dir}"/*.dtb)
  ((${#dtbs[@]})) && install -m 0644 "${dtbs[@]}" "${dest_root}/boot/"
  # overlays (includes clockworkpi-uconsole-cm4.dtbo)
  mkdir -p "${dest_root}/boot/overlays"
  local ovls=("${out_dir}"/overlays/*.dtbo)
  ((${#ovls[@]})) && install -m 0644 "${ovls[@]}" "${dest_root}/boot/overlays/"
  [[ -f "${out_dir}/overlays/README" ]] \
    && install -m 0644 "${out_dir}/overlays/README" "${dest_root}/boot/overlays/"
  shopt -u nullglob

  # modules (already modules_install'd; relative paths in modules.dep stay valid).
  # A new kver lands in its own dir, so an existing kernel's modules survive.
  [[ -d "${modules_dir}/lib/modules/${kver}" ]] \
    || die "modules not found: ${modules_dir}/lib/modules/${kver}"
  mkdir -p "${dest_root}/usr/lib/modules"
  cp -a "${modules_dir}/lib/modules/${kver}" "${dest_root}/usr/lib/modules/"

  ok "kernel installed: ${dest_root:-/}/boot/kernel8-cm4.img + overlays + /usr/lib/modules/${kver}"
}
