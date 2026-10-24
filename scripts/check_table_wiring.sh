#!/bin/bash
# ============================================================
# check_table_wiring.sh —— 共享列表页 table 装配完整性静态检查
#
# 背景（v1.0.79-fix1）：deb 装机实测「记录与映射」打开一片空白——根因是
# PTUIPlansVC 建了 self.tv 却漏设 dataSource/delegate（v1.0.71「8 页收敛
# 共享 VC」重构漏行），numberOfRowsInSection 永不被调用，页面全白。
# 这类「UI 装配漏一行」编译期零暴露（协议声明在 .h，编译器不强制赋值）、
# 运行期直接白屏，只能靠文本级检查兜住。
#
# 规则：凡是建了 self.tv（自建 or 经 setupGroupedTableWithTop）的共享 VC，
# 同一文件内必须出现 .dataSource = self 与 .delegate = self。
# 新增共享列表页时忘记赋值 → 本关立即失败，不再等真机白屏。
# ============================================================
set -u
cd "$(dirname "$0")/.."

FAIL=0
CHECKED=0

# 注意：不用 mapfile——macOS 的 /bin/bash 是 3.2，没有该内建
FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && FILES+=("$f")
done < <(git ls-files 'common/PTUI*.m')

if [ ${#FILES[@]} -eq 0 ]; then
  echo "check_table_wiring: ✗ 未发现任何 common/PTUI*.m（git ls-files 异常？）" >&2
  exit 1
fi

for f in "${FILES[@]}"; do
  # 基类除外：PTUIBaseListVC 的设计职责就是建 table，dataSource/delegate 由子类设置
  [ "$(basename "$f")" = "PTUIBaseListVC.m" ] && continue
  # 只检查「建了共享 table」的文件：自建 self.tv，或调用基类 setupGroupedTableWithTop
  if grep -qE 'self\.tv = |setupGroupedTableWithTop' "$f"; then
    CHECKED=$((CHECKED + 1))
    if ! grep -q '\.dataSource = self' "$f"; then
      echo "check_table_wiring: ✗ $f 建了 self.tv 但未设置 .dataSource = self —— 页面将全白（numberOfRows 永不被调用）" >&2
      FAIL=1
    fi
    if ! grep -q '\.delegate = self' "$f"; then
      echo "check_table_wiring: ✗ $f 建了 self.tv 但未设置 .delegate = self —— 行点击/滑动删除静默失效" >&2
      FAIL=1
    fi
  fi
done

if [ "$CHECKED" -eq 0 ]; then
  echo "check_table_wiring: ✗ 没有任何文件命中「建 table」规则（规则本身失效？）" >&2
  exit 1
fi

if [ "$FAIL" -ne 0 ]; then
  echo "check_table_wiring: ✗ table 装配不完整（见上）" >&2
  exit 1
fi

echo "check_table_wiring: OK（${CHECKED} 个共享列表页 dataSource/delegate 均已设置）"
