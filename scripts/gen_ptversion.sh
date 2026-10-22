#!/usr/bin/env bash
# 生成 common/PTVersion.h —— 编译期横幅宏真源（.gitignore 收录的生成物，禁止手改/提交）。
# 版本号解析自 Makefile 的 PACKAGE_VERSION（单一真源不变）。
#
# 为什么单独一个脚本（而不是只在 sync_version.sh 里）：
#   · CI 在 checkout 后、check_version.sh 之前调用它 —— 保证编译期头文件必然存在，
#     尤其巨魔 dylib 走裸 clang 构建、不过 make 钩子，缺了它直接编译失败。
#   · sync_version.sh 打包前也委托它生成，逻辑单一实现、不漂移。
set -euo pipefail

cd "$(dirname "$0")/.."   # 切到仓库根

VER="$(python3 - "$PWD/Makefile" <<'PY'
import sys, re
t = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'^\s*PACKAGE_VERSION\s*:?=\s*(\S+)', t, re.M)
print(m.group(1) if m else "")
PY
)"
if [ -z "${VER}" ]; then
  echo "gen_ptversion.sh: 无法从 Makefile 解析 PACKAGE_VERSION" >&2
  exit 1
fi

python3 - "${VER}" "$PWD/common/PTVersion.h" <<'PY'
import sys
ver, path = sys.argv[1], sys.argv[2]
body = (
    "// 本文件由 scripts/gen_ptversion.sh 从 Makefile 的 PACKAGE_VERSION 自动生成，\n"
    "// 请勿手改、勿提交（.gitignore 已收录）。源码层横幅一律引用 PT_VERSION_STRING。\n"
    "#ifndef PT_VERSION_H\n"
    "#define PT_VERSION_H\n"
    "\n"
    '#define PT_VERSION_STRING @"' + ver + '"\n'
    "\n"
    "#endif  // PT_VERSION_H\n"
)
open(path, 'w', encoding='utf-8').write(body)
PY

echo "gen_ptversion.sh: common/PTVersion.h → PT_VERSION_STRING @\"${VER}\""
