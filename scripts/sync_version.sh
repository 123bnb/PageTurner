#!/usr/bin/env bash
# 版本号单一真源：从 Makefile 的 PACKAGE_VERSION 派生
#   · control                          (Version:)
#   · Preferences/Resources/Info.plist (CFBundleShortVersionString / CFBundleVersion)
#   · common/PTVersion.h               (#define PT_VERSION_STRING，编译期横幅宏)
# 消除「三处手填 + 源码层硬编码横幅」漂移。由 Makefile 的 before-package:: 在打包前自动调用。
# 注：PTVersion.h 的生成委托给 scripts/gen_ptversion.sh（CI 在 checkout 后单独调它，
# 因为巨魔 dylib 走裸 clang、不过 make 钩子，编译前头文件必须已在）。
#
# 健壮性：
#   · 跨平台用 python3 做改写（macOS Actions 与 Linux 均自带 python3），
#     避免 GNU/BSD sed -i 语法差异。
#   · plist 按 <key> 锚定替换，不会误伤其它 X.Y.Z 形式的 <string>。
#   · 四处已一致则提前退出（PTVersion.h 是 .gitignore 收录的生成物，不影响工作树洁净）。
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
# PTVersion.h 可能尚未生成（全新 checkout / CI 首次构建前）——取不到记空串
cur_macro="$(python3 - "$PWD/common/PTVersion.h" <<'PY'
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

if [ "${VER}" = "${cur_control}" ] && [ "${VER}" = "${cur_short}" ] && [ "${VER}" = "${cur_ver}" ] && [ "${VER}" = "${cur_macro}" ]; then
  # tracked 三处已一致；PTVersion.h 是 gitignore 生成物，幂等重建保证编译期可用
  bash "$PWD/scripts/gen_ptversion.sh" >/dev/null
  echo "sync_version.sh: 四处已一致 (${VER})，跳过写入"
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

# common/PTVersion.h：编译期横幅宏（.gitignore 生成物，禁止手改/提交）。
# 生成逻辑单一实现在 scripts/gen_ptversion.sh，此处委托，避免两处实现漂移。
bash "$PWD/scripts/gen_ptversion.sh"

echo "sync_version.sh: 完成（已就地更新 control / Info.plist / common/PTVersion.h；打包后由 Makefile 的 after-package:: 还原 control 与 Info.plist）"
