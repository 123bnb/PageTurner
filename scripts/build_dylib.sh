#!/usr/bin/env bash
# ============================================================
# build_dylib.sh —— 本地一键构建 TrollStore/巨魔 dylib（arm64 + arm64e）
# ============================================================
# 背景（v1.0.78，评审 #1）：dylib 走裸 clang（无 theos / 无 Logos / 无 ellekit），
# 此前**只有 CI 一条构建路径**——本地改 dylib 侧代码无法自行验证，v1.0.77 连炸
# 5 轮 CI（每轮都要付 clone Theos + 全量编译的时间成本）才补全 import。
# 本脚本把 CI 的 dylib 构建步骤原样搬到本地：
#   1. 前置检查（clang / make / ldid / lipo / nm / iOS SDK）
#   2. 从 build/sources.mk 读源文件列表 + flags（与 CI 同一单一真源）
#   3. clang 编 arm64+arm64e 胖包（失败则仅 arm64 并**响亮警告**——CI 会拦）
#   4. strip -x + ldid -S（v1.0.78 体积回补，见 sources.mk 的 DYLIB_*FLAGS）
#   5. 审计：无 substrate 未定义符号 / arm64e slice 必须存在
#
# 用法：
#   bash scripts/build_dylib.sh                      # 输出 out/PageTurnerDylib_<ver>.dylib
#   SDK=/path/to/iPhoneOS.sdk bash scripts/build_dylib.sh
#   THEOS=/path/to/theos bash scripts/build_dylib.sh
# 环境变量：THEOS（默认 <repo>/theos）/ SDK（显式指定，优先于自动发现）/ OUT（显式输出路径）
# 退出码：0 = 构建并审计通过；非零 = 前置缺失或编译/审计失败（原因逐条打印）
# ============================================================
set -uo pipefail
cd "$(dirname "$0")/.."

THEOS="${THEOS:-$PWD/theos}"

# ---------- 1. 前置检查 ----------
for tool in make clang lipo nm; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "✗ 缺少工具: $tool（macOS 需先装 Xcode 命令行工具: xcode-select --install）"; exit 1; }
done
command -v ldid >/dev/null 2>&1 || {
  echo "✗ 缺少 ldid（brew install ldid）"; exit 1; }

# SDK 发现：$SDK 显式指定 > $THEOS/sdks/iPhoneOS*.sdk（取字典序最大）> xcrun
if [ -z "${SDK:-}" ] || [ ! -d "${SDK:-}" ]; then
  SDK="$(ls -d "$THEOS"/sdks/iPhoneOS*.sdk 2>/dev/null | sort | tail -1 || true)"
fi
if [ -z "${SDK:-}" ] || [ ! -d "$SDK" ]; then
  SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
fi
if [ -z "${SDK:-}" ] || [ ! -d "$SDK" ]; then
  echo "✗ 找不到 iOS SDK。请设置 SDK=/path/to/iPhoneOS.sdk，"
  echo "  或把 SDK 放到 \$THEOS/sdks/（CI 的做法：git clone theos/sdks 取 iPhoneOS16.5.sdk）"
  exit 1
fi
echo "SDK = $SDK"

# ---------- 2. 版本号与源列表（单一真源：build/sources.mk，与 CI 同口径） ----------
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  VER="$(git describe --tags --abbrev=0 2>/dev/null || echo "dev-$(git rev-parse --short HEAD)")"
else
  VER="local"
fi
OUT="${OUT:-out/PageTurnerDylib_${VER}.dylib}"
mkdir -p "$(dirname "$OUT")"

SRCS=$(make -s -f build/sources.mk PRINT_CONFIG=1 print-dylib-sources)
SHARED_CFLAGS=$(make -s -f build/sources.mk PRINT_CONFIG=1 print-cflags)
DYLIB_CFLAGS=$(make -s -f build/sources.mk PRINT_CONFIG=1 print-dylib-cflags)
DYLIB_LDFLAGS=$(make -s -f build/sources.mk PRINT_CONFIG=1 print-dylib-ldflags)
[ -n "$SRCS" ] || { echo "✗ build/sources.mk 未返回 dylib 源文件列表"; exit 1; }

echo "版本   : $VER"
echo "输出   : $OUT"
echo "cflags : $SHARED_CFLAGS $DYLIB_CFLAGS"
echo "ldflags: -Wl,-undefined,dynamic_lookup $DYLIB_LDFLAGS"
echo "源文件 :"
for s in $SRCS; do echo "    $s"; done

build_one() {   # $1 = clang -arch 参数串
  # shellcheck disable=SC2086
  clang $1 -isysroot "$SDK" -miphoneos-version-min=15.0 \
    $SHARED_CFLAGS $DYLIB_CFLAGS \
    -Wl,-undefined,dynamic_lookup $DYLIB_LDFLAGS \
    -framework Foundation -framework UIKit \
    -dynamiclib $SRCS -o "$OUT"
}

# ---------- 3. 编译（arm64+arm64e 优先；仅 arm64 只警告、绝不静默） ----------
if build_one "-arch arm64 -arch arm64e"; then
  echo "✓ 编译 OK (arm64+arm64e)"
else
  echo "⚠ arm64+arm64e 编译失败，降级仅 arm64——此产物**不可发布**（CI 的 arm64e 校验会拦）" >&2
  build_one "-arch arm64" || { echo "✗ 仅 arm64 也编译失败"; exit 1; }
  echo "✓ 编译 OK (仅 arm64)"
fi

# ---------- 4. strip + 签名 ----------
strip -x "$OUT" && echo "✓ strip OK（剥离本地符号，v1.0.78 体积回补）"
ldid -S "$OUT" && echo "✓ ldid 签名 OK"
file "$OUT"
ls -la "$OUT"

# ---------- 5. 审计（与 CI 同一口径） ----------
fail=0
nm -u "$OUT" > /tmp/pt_dylib_undef.txt 2>/dev/null || true
SUBS=$(grep -E '_MSHook|_MSGetImageByName|_MSFindSymbol|_Substrate' /tmp/pt_dylib_undef.txt || true)
if [ -n "$SUBS" ]; then
  echo "✗ 发现 substrate 未定义符号（TrollStore 无 substrate 可解析，首次调用即崩）："
  echo "$SUBS"; fail=1
else
  echo "✓ 无 substrate 未定义符号"
fi
if lipo -info "$OUT" | grep -q arm64e; then
  echo "✓ arm64e slice 存在"
else
  echo "✗ 缺少 arm64e slice（iOS 15/16 上大量 App 是 arm64e，注入会失败）"; fail=1
fi
if [ "$fail" -ne 0 ]; then exit 1; fi
echo "============================================================"
echo "构建完成: $OUT"
echo "============================================================"
