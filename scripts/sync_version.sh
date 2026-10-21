#!/usr/bin/env bash
# 版本号单一真源：从 Makefile 的 PACKAGE_VERSION 派生
#   · control          (Version:)
#   · Preferences/Resources/Info.plist (CFBundleShortVersionString / CFBundleVersion)
# 消除「三处手填」漂移。由 Makefile 的 before-package:: 在打包前自动调用。
#
# 跨平台：用 python3 做原地改写（macOS Actions 与 Linux 均自带 python3），
#         避免 GNU sed 与 BSD sed 在 `sed -i` 语法上的差异。
set -euo pipefail

cd "$(dirname "$0")/.."   # 切到仓库根

# 从 Makefile 解析 PACKAGE_VERSION
VER="$(python3 - "$PWD/Makefile" <<'PY'
import sys, re
t = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'^\s*PACKAGE_VERSION\s*:?=\s*(\S+)', t, re.M)
print(m.group(1) if m else "")
PY
)"

if [ -z "${VER}" ]; then
  echo "sync_version.sh: 无法从 Makefile 解析 PACKAGE_VERSION" >&2
  exit 1
fi

echo "sync_version.sh: 派生版本号 = ${VER}"

# control：重写 Version: 行
python3 - "${VER}" "$PWD/control" <<'PY'
import sys, re
ver, path = sys.argv[1], sys.argv[2]
s = open(path, encoding='utf-8').read()
s2 = re.sub(r'^(Version:\s*).*$', lambda m: m.group(1) + ver, s, flags=re.M)
open(path, 'w', encoding='utf-8').write(s2)
PY

# Info.plist：仅替换三段式版本号字符串（1.0.67 这类），不动 Name/DisplayName 等
python3 - "${VER}" "$PWD/Preferences/Resources/Info.plist" <<'PY'
import sys, re
ver, path = sys.argv[1], sys.argv[2]
s = open(path, encoding='utf-8').read()
s2 = re.sub(r'(<string>)\d+\.\d+\.\d+(</string>)',
            lambda m: m.group(1) + ver + m.group(2), s)
open(path, 'w', encoding='utf-8').write(s2)
PY

echo "sync_version.sh: 完成"
