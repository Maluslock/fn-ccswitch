#!/usr/bin/env bash
# Build fn-ccswitch.fpk
#
#   ./scripts/build.sh                # 完整构建（下载上游 → 构建前端 → 组装 → fnpack）
#   ./scripts/build.sh --skip-web     # 复用 build/web 里已有的前端产物
#   ./scripts/build.sh --skip-pack    # 只组装 pkg，不调用 fnpack
#
# 依赖：curl、tar、dpkg-deb、node ≥ 20、pnpm、fnpack
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${BUILD_DIR:-$ROOT/build}"
APPNAME="fn-ccswitch"
CCSW_TAG="${CCSW_TAG:-v3.20.2}"
API_PREFIX="/app/${APPNAME}/api"
PAGE_PREFIX="/app/${APPNAME}/"
LIBS_URL="${LIBS_URL:-http://deb.debian.org/debian/pool/main/o/openssl/libssl1.1_1.1.1w-0+deb11u1_amd64.deb}"
FNPACK_BIN="${FNPACK_BIN:-fnpack}"

SKIP_WEB=0
SKIP_PACK=0
for arg in "$@"; do
  case "$arg" in
    --skip-web) SKIP_WEB=1 ;;
    --skip-pack) SKIP_PACK=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

mkdir -p "$BUILD"/{cache,backend,src,web}

# ---------------------------------------------------------------- 上游二进制
fetch_backend() {
  local out="$BUILD/backend/cc-switch-web"
  if [ -x "$out" ]; then step "后端二进制已存在：$out"; return; fi
  local name="cc-switch-web-${CCSW_TAG}-linux-x86_64-ubuntu20.04"
  local url="https://github.com/cp-yu/cc-switch-web/releases/download/${CCSW_TAG}/${name}"
  step "下载 cc-switch-web ${CCSW_TAG}"
  curl -fSL --retry 3 --retry-delay 2 -o "$out.part" "$url"
  chmod 0755 "$out.part"
  mv "$out.part" "$out"
}

# ---------------------------------------------------------- OpenSSL 1.1 运行库
fetch_libs() {
  local libdir="$BUILD/backend/lib"
  mkdir -p "$libdir"
  if [ -f "$libdir/libssl.so.1.1" ] && [ -f "$libdir/libcrypto.so.1.1" ]; then
    step "OpenSSL 1.1 运行库已存在"; return
  fi
  local deb="$BUILD/cache/libssl1.1.deb"
  if [ ! -f "$deb" ]; then
    step "下载 libssl1.1（上游二进制基于 Ubuntu 20.04 构建）"
    curl -fSL --retry 3 -o "$deb.part" "$LIBS_URL"
    mv "$deb.part" "$deb"
  fi
  step "解出 libssl.so.1.1 / libcrypto.so.1.1"
  local tmp; tmp="$(mktemp -d)"
  dpkg-deb -x "$deb" "$tmp"
  cp -f "$tmp"/usr/lib/x86_64-linux-gnu/libssl.so.1.1 "$libdir/"
  cp -f "$tmp"/usr/lib/x86_64-linux-gnu/libcrypto.so.1.1 "$libdir/"
  rm -rf "$tmp"
}

# ------------------------------------------------------------------- 前端构建
fetch_source() {
  local tarball="$BUILD/cache/ccsw-${CCSW_TAG}.tar.gz"
  if [ ! -f "$tarball" ]; then
    step "下载前端源码 ${CCSW_TAG}"
    curl -fSL --retry 3 -o "$tarball.part" \
      "https://codeload.github.com/cp-yu/cc-switch-web/tar.gz/refs/tags/${CCSW_TAG}"
    mv "$tarball.part" "$tarball"
  fi
  if [ ! -f "$BUILD/src/package.json" ]; then
    step "解压源码"
    rm -rf "$BUILD/src"; mkdir -p "$BUILD/src"
    tar xzf "$tarball" -C "$BUILD/src" --strip-components=1
  fi
  apply_patches
}

# 上游源码的本地补丁（见 patches/README.md）。幂等：已应用则跳过；上游变动导致冲突则报错。
apply_patches() {
  local dir="$ROOT/patches" p
  [ -d "$dir" ] || return 0
  for p in "$dir"/*.patch; do
    [ -f "$p" ] || continue
    if patch -p1 --forward --silent --dry-run -d "$BUILD/src" <"$p" >/dev/null 2>&1; then
      step "应用补丁 $(basename "$p")"
      patch -p1 --forward --silent -d "$BUILD/src" <"$p" \
        || die "补丁应用失败：$(basename "$p")（上游代码可能已变更）"
    elif patch -p1 --forward --silent --reverse --dry-run -d "$BUILD/src" <"$p" >/dev/null 2>&1; then
      echo "  已应用，跳过：$(basename "$p")"
    else
      die "补丁冲突：$(basename "$p")（上游代码可能已变更，请重新生成）"
    fi
  done
}

build_web() {
  if [ "$SKIP_WEB" = 1 ] && [ -f "$BUILD/web/index.html" ]; then
    step "--skip-web：复用已有前端产物"; return
  fi
  fetch_source
  step "安装前端依赖（pnpm）"
  # pnpm 需要可写的 HOME / 缓存目录；构建机默认 HOME 可能是只读的（例如装在 NAS 应用目录里），
  # 否则会报 "unable to open database file"。统一把缓存重定向到 $BUILD/home。
  local fhome="$BUILD/home"
  mkdir -p "$fhome/.cache" "$fhome/.npm-cache" "$fhome/.config" "$BUILD/.pnpm-store"
  ( cd "$BUILD/src" && \
    HOME="$fhome" \
    XDG_CACHE_HOME="$fhome/.cache" \
    XDG_CONFIG_HOME="$fhome/.config" \
    XDG_DATA_HOME="$fhome/.local/share" \
    npm_config_cache="$fhome/.npm-cache" \
    pnpm install --frozen-lockfile --ignore-scripts --store-dir "$BUILD/.pnpm-store" )
  step "构建 Web 前端（API 前缀 ${API_PREFIX}）"
  # --base 必须是绝对路径：桌面 iframe 的地址是 /app/fn-ccswitch（没有结尾斜杠），
  # 若 index.html 里是 "./assets/..." 就会解析到 /app/assets/... → 404 → 白屏。
  ( cd "$BUILD/src" && \
    VITE_CC_SWITCH_MODE=ws \
    VITE_CC_SWITCH_API_BASE="$API_PREFIX" \
    ./node_modules/.bin/vite build --mode web --base="$PAGE_PREFIX" )
  [ -f "$BUILD/src/dist/index.html" ] || die "前端构建失败：找不到 dist/index.html"
  step "复制前端产物到 $BUILD/web"
  rm -rf "$BUILD/web"; mkdir -p "$BUILD/web"
  cp -a "$BUILD/src/dist/." "$BUILD/web/"
  grep -rq "$API_PREFIX" "$BUILD/web/assets" \
    || die "前端产物里没有注入 ${API_PREFIX}，请检查 VITE_CC_SWITCH_API_BASE"
}

# --------------------------------------------------------------------- 组装
assemble() {
  local pkg="$BUILD/pkg"
  step "组装 $pkg"
  rm -rf "$pkg"
  cp -a "$ROOT/pkg" "$pkg"
  mkdir -p "$pkg/app/web" "$pkg/app/bin" "$pkg/app/lib"
  cp -a "$BUILD/web/." "$pkg/app/web/"
  cp -f "$BUILD/backend/cc-switch-web" "$pkg/app/bin/cc-switch-web"
  cp -f "$BUILD"/backend/lib/*.so.1.1 "$pkg/app/lib/"
  chmod 0755 "$pkg/app/bin/cc-switch-web"
  chmod 0644 "$pkg/app/gateway-proxy.mjs"
  chmod 0755 "$pkg"/cmd/*
  # 归一化权限：构建机 umask 可能是 077，会把 manifest / cmd / 图标打成 0600、0700，
  # 安装器与应用包用户都可能读不到。统一成 0755 目录 + 0644 文件 + 可执行位。
  find "$pkg" -type d -exec chmod 0755 {} +
  find "$pkg" -type f -exec chmod 0644 {} +
  chmod 0755 "$pkg/app/bin/cc-switch-web" "$pkg"/cmd/*
  du -sh "$pkg" | sed 's/^/    /'
}

pack() {
  if [ "$SKIP_PACK" = 1 ]; then step "--skip-pack：跳过 fnpack"; return; fi
  command -v "$FNPACK_BIN" >/dev/null || die "未找到 fnpack，请先安装：https://developer.fnnas.com/docs/cli/fnpack/"
  step "fnpack build"
  ( cd "$BUILD/pkg" && "$FNPACK_BIN" build )
  mkdir -p "$ROOT/dist"
  cp -f "$BUILD/pkg/$APPNAME.fpk" "$ROOT/dist/$APPNAME.fpk"
  ls -lh "$ROOT/dist/$APPNAME.fpk"
}

fetch_backend
fetch_libs
build_web
assemble
pack
step "完成：$ROOT/dist/$APPNAME.fpk"
