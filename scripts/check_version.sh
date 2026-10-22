#!/usr/bin/env bash
# 校验版本号四处一致：Makefile(PACKAGE_VERSION) == control(Version)
#                    == Info.plist(CFBundleShortVersionString / CFBundleVersion)
#                    == common/PTVersion.h(PT_VERSION_STRING)
# 并扫描源码层硬编码横幅：禁止任何 ObjC 字面量 @"PageTurner...vX.Y.Z"（一律用 PT_VERSION_STRING）。
# 不一致/有硬编码则非零退出，CI 在打包前拦截，根治「三处手填 + 源码层横幅」漂移。
#
# 跨平台：用 python3 提取版本号（macOS Actions 与 Linux 均自带 python3）。
set -euo pipefail

cd "$(dirname "$0")/.."

mk="$(python3 - "$PWD/Makefile" <<'PY'
import sys, re
t = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'^\s*PACKAGE_VERSION\s*:?=\s*(\S+)', t, re.M)
print(m.group(1) if m else "")
PY
)"
ct="$(python3 - "$PWD/control" <<'PY'
import sys, re
t = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'^Version:\s*(\S+)', t, re.M)
print(m.group(1) if m else "")
PY
)"
pl_short="$(python3 - "$PWD/Preferences/Resources/Info.plist" <<'PY'
import sys, re
t = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'CFBundleShortVersionString</key>\s*<string>([^<]+)</string>', t)
print(m.group(1) if m else "")
PY
)"
pl_ver="$(python3 - "$PWD/Preferences/Resources/Info.plist" <<'PY'
import sys, re
t = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'CFBundleVersion</key>\s*<string>([^<]+)</string>', t)
print(m.group(1) if m else "")
PY
)"
macro="$(python3 - "$PWD/common/PTVersion.h" <<'PY'
import sys, re, os
p = sys.argv[1]
if not os.path.exists(p):
    print("")
else:
    t = open(p, encoding='utf-8').read()
    m = re.search(r'#define\s+PT_VERSION_STRING\s+@"([^"]+)"', t)
    print(m.group(1) if m else "")
PY
)"

echo "Makefile PACKAGE_VERSION      = ${mk}"
echo "control Version               = ${ct}"
echo "Info.plist ShortVersionString = ${pl_short}"
echo "Info.plist CFBundleVersion    = ${pl_ver}"
echo "PTVersion.h PT_VERSION_STRING = ${macro}"

fail=0
[ "${mk}" = "${ct}" ]       || { echo "✗ control(${ct}) != Makefile(${mk})"; fail=1; }
[ "${mk}" = "${pl_short}" ] || { echo "✗ Info.plist ShortVersion(${pl_short}) != Makefile(${mk})"; fail=1; }
[ "${mk}" = "${pl_ver}" ]   || { echo "✗ Info.plist CFBundleVersion(${pl_ver}) != Makefile(${mk})"; fail=1; }
[ "${mk}" = "${macro}" ]    || { echo "✗ PTVersion.h macro(${macro}) != Makefile(${mk})"; fail=1; }

# ---------- 源码层硬编码横幅扫描 ----------
# 只扫 .m 源文件目录（避开 .git 里的历史对象，那里有合法的旧版本字面量）。
# 锚定 @"PageTurner(Dylib)? vX.Y.Z 字面量开头，不会误伤
# 「PageTurner-%@.log」「PageTurnerDylib」标题、或注释里的「v1.0.5 已删除」历史叙述。
banner_hits="$(grep -rnE '@"PageTurner(Dylib)? v[0-9]+\.[0-9]+\.[0-9]+' \
    --include='*.m' Tweak.m common ptftouch targets Preferences 2>/dev/null || true)"
if [ -n "${banner_hits}" ]; then
  echo "✗ 源码层发现硬编码版本横幅（应改为 PT_VERSION_STRING）："
  echo "${banner_hits}"
  fail=1
fi

if [ "${fail}" -ne 0 ]; then
  echo "版本号不一致或存在硬编码横幅，构建中止。请运行 bash scripts/sync_version.sh 后再提交。"
  exit 1
fi
echo "✓ 版本号四处一致 (${mk})，且无源码层硬编码横幅"
