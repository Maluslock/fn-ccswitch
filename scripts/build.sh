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
}

build_web() {
  if [ "$SKIP_WEB" = 1 ] && [ -f "$BUILD/web/index.html" ]; then
    step "--skip-web：复用已有前端产物"; return
  fi
  fetch_source
  step "安装前端依赖（pnpm）"
  ( cd "$BUILD/src" && pnpm install --frozen-lockfile --ignore-scripts )
  step "构建 Web 前端（API 前缀 ${API_PREFIX}）"
  ( cd "$BUILD/src" && \
    VITE_CC_SWITCH_MODE=ws \
    VITE_CC_SWITCH_API_BASE="$API_PREFIX" \
    ./node_modules/.bin/vite build --mode web )
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
