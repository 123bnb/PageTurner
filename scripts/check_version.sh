#!/usr/bin/env bash
# 校验版本号三处一致：Makefile(PACKAGE_VERSION) == control(Version)
#                    == Info.plist(CFBundleShortVersionString / CFBundleVersion)
# 不一致则非零退出，CI 在打包前拦截，根治「三处手填」漂移。
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

echo "Makefile PACKAGE_VERSION      = ${mk}"
echo "control Version               = ${ct}"
echo "Info.plist ShortVersionString = ${pl_short}"
echo "Info.plist CFBundleVersion    = ${pl_ver}"

fail=0
[ "${mk}" = "${ct}" ]       || { echo "✗ control(${ct}) != Makefile(${mk})"; fail=1; }
[ "${mk}" = "${pl_short}" ] || { echo "✗ Info.plist ShortVersion(${pl_short}) != Makefile(${mk})"; fail=1; }
[ "${mk}" = "${pl_ver}" ]   || { echo "✗ Info.plist CFBundleVersion(${pl_ver}) != Makefile(${mk})"; fail=1; }

if [ "${fail}" -ne 0 ]; then
  echo "版本号不一致，构建中止。请运行 bash scripts/sync_version.sh 后再提交。"
  exit 1
fi
echo "✓ 版本号三处一致 (${mk})"
