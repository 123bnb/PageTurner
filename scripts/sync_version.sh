#!/usr/bin/env bash
# 版本号单一真源：从 Makefile 的 PACKAGE_VERSION 派生
#   · control          (Version:)
#   · Preferences/Resources/Info.plist (CFBundleShortVersionString / CFBundleVersion)
# 消除「三处手填」漂移。由 Makefile 的 before-package:: 在打包前自动调用。
#
# 健壮性：
#   · 跨平台用 python3 做改写（macOS Actions 与 Linux 均自带 python3），
#     避免 GNU/BSD sed -i 语法差异。
#   · plist 按 <key> 锚定替换，不会误伤其它 X.Y.Z 形式的 <string>。
#   · 三处已一致则提前退出，避免无谓写入（也避免本地 make package 脏工作树）。
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

# 当前工作树版本（用于早退判断）
cur_control="$(python3 - "$PWD/control" <<'PY'
import sys, re
t = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'^Version:\s*(\S+)', t, re.M)
print(m.group(1) if m else "")
PY
)"
cur_short="$(python3 - "$PWD/Preferences/Resources/Info.plist" <<'PY'
import sys, re
t = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'CFBundleShortVersionString</key>\s*<string>([^<]+)</string>', t)
print(m.group(1) if m else "")
PY
)"
cur_ver="$(python3 - "$PWD/Preferences/Resources/Info.plist" <<'PY'
import sys, re
t = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'CFBundleVersion</key>\s*<string>([^<]+)</string>', t)
print(m.group(1) if m else "")
PY
)"

if [ "${VER}" = "${cur_control}" ] && [ "${VER}" = "${cur_short}" ] && [ "${VER}" = "${cur_ver}" ]; then
  echo "sync_version.sh: 三处已一致 (${VER})，跳过写入"
  exit 0
fi

echo "sync_version.sh: 派生版本号 = ${VER}"

# control
python3 - "${VER}" "$PWD/control" <<'PY'
import sys, re
ver, path = sys.argv[1], sys.argv[2]
s = open(path, encoding='utf-8').read()
s2 = re.sub(r'^(Version:\s*).*$', lambda m: m.group(1) + ver, s, flags=re.M)
open(path, 'w', encoding='utf-8').write(s2)
PY

# Info.plist：按 <key> 锚定，只改版本号那两处 <string>
python3 - "${VER}" "$PWD/Preferences/Resources/Info.plist" <<'PY'
import sys, re
ver, path = sys.argv[1], sys.argv[2]
s = open(path, encoding='utf-8').read()
for key in ("CFBundleShortVersionString", "CFBundleVersion"):
    s = re.sub(
        r'(<key>' + re.escape(key) + r'</key>\s*)<string>[^<]*</string>',
        lambda m: m.group(1) + f'<string>{ver}</string>',
        s)
open(path, 'w', encoding='utf-8').write(s)
PY

echo "sync_version.sh: 完成（已就地更新 control / Info.plist；打包后由 Makefile 的 after-package:: 还原工作树）"
