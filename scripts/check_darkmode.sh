#!/bin/bash
# ============================================================
# check_darkmode.sh —— UI 层深色模式色彩安全静态检查
#
# 背景：系统深色模式会把容器背景变暗。UI 层若把背景/文字色写死成
# 白/黑/灰（UIColor whiteColor、colorWithWhite: 等），深色模式下
# 要么「暗底白块」糊成一片，要么「暗底黑字」直接不可读。这类问题
# 编译期零暴露、浅色模式下肉眼完全正常，只有用户开深色模式才炸——
# 与 v1.0.79 白屏 bug 同一类「装配漏一行」，只能靠文本级门禁兜住。
#
# 规则（扫描 common/PTUI*.m 与 Preferences/*.m）：
#   R1 背景写死：backgroundColor = [UIColor (white|black|darkGray|
#      lightGray|gray)Color] 或 [UIColor colorWithWhite:...] → 违规。
#      背景是深色模式灾难根源（白底不跟随系统变暗）。
#   R2 文字写死（白除外）：textColor = [UIColor (black|darkGray|
#      lightGray|gray)Color] 或 colorWithWhite: → 违规。
#      白字放行——白字只出现在彩色底按钮/标签上（如 PTUIPlanVC 蓝底/
#      橙底按钮、连滑 pill 绿底白字），彩色底不随深色模式变化，
#      白字是既定设计且两模式下均可读。
#   R3 直写彩色无动态适配：文件用了 colorWithRed:green:blue:（直写
#      彩色）却同文件没有 colorWithDynamicProvider → 违规（唯一合法
#      容器是动态 Provider 块，块内按 userInterfaceStyle 分支换色）。
#
# 深色模式安全速查表（新增/修改 UI 代码时对照）：
#   背景  systemGroupedBackgroundColor / secondarySystemGroupedBackgroundColor
#         systemBackgroundColor / secondarySystemBackgroundColor
#         tertiarySystemBackgroundColor
#   文字  labelColor / secondaryLabelColor / tertiaryLabelColor
#   分隔  separatorColor
#   状态  systemGreenColor / systemRedColor / systemBlueColor /
#         systemOrangeColor / systemYellowColor
#   彩色底白字  [UIColor whiteColor]（仅 textColor，配合非系统彩色底）
#   直写彩色    必须包在 colorWithDynamicProvider 块内按深浅分支
#
# 行内豁免：行尾含 `// dm-ok` 的行跳过（确有把握的例外，需注释理由）。
#
# 防空转：文件列表为空、或扫描范围内一处 UIColor 赋值都匹配不到
# （模式/范围失效）→ 直接失败，绝不假通过。
# ============================================================
set -u
cd "$(dirname "$0")/.."

FAIL=0
SCANNED=0     # 参与扫描的文件数
COLOR_HITS=0  # 扫描范围内 UIColor 赋值总数（防空转：为 0 即模式失效）

# 注意：不用 mapfile——macOS 的 /bin/bash 是 3.2，没有该内建（v1.0.78-fix 踩坑）
FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && FILES+=("$f")
done < <(git ls-files 'common/PTUI*.m' 'Preferences/*.m')

if [ ${#FILES[@]} -eq 0 ]; then
  echo "check_darkmode: ✗ 未发现任何待扫描文件（git ls-files 异常？）" >&2
  exit 1
fi

# 违规行统一上报（行内 // dm-ok 豁免）
report() {
  echo "check_darkmode: ✗ $1" >&2
  FAIL=1
}

for f in "${FILES[@]}"; do
  SCANNED=$((SCANNED + 1))
  # 行内豁免过滤后的临时视图
  BODY=$(grep -v 'dm-ok' "$f" || true)

  # 防空转计数：本文件出现 UIColor 赋值即计入
  if echo "$BODY" | grep -q 'UIColor'; then
    COLOR_HITS=$((COLOR_HITS + 1))
  fi

  # R1a 背景写死中性色
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    report "$f:$line  —— 背景色必须跟随深色模式，改用 systemGroupedBackgroundColor / systemBackgroundColor 等系统语义色"
  done < <(echo "$BODY" | grep -nE '(\.backgroundColor[[:space:]]*=[[:space:]]*\[UIColor|setBackgroundColor:[[:space:]]*\[UIColor)[[:space:]]+(white|black|darkGray|lightGray|gray)Color\]' || true)

  # R1b 背景写死灰阶
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    report "$f:$line  —— colorWithWhite: 是写死灰阶，背景请改用系统语义色"
  done < <(echo "$BODY" | grep -nE '(\.backgroundColor[[:space:]]*=[[:space:]]*\[UIColor|setBackgroundColor:[[:space:]]*\[UIColor)[[:space:]]+colorWithWhite:' || true)

  # R2a 文字写死中性色（白除外——彩色底白字是既定设计）
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    report "$f:$line  —— 文字色深色模式下将不可读，改用 labelColor / secondaryLabelColor"
  done < <(echo "$BODY" | grep -nE '(\.textColor[[:space:]]*=[[:space:]]*\[UIColor|setTextColor:[[:space:]]*\[UIColor)[[:space:]]+(black|darkGray|lightGray|gray)Color\]' || true)

  # R2b 文字写死灰阶
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    report "$f:$line  —— colorWithWhite: 是写死灰阶，文字请改用 labelColor 系"
  done < <(echo "$BODY" | grep -nE '(\.textColor[[:space:]]*=[[:space:]]*\[UIColor|setTextColor:[[:space:]]*\[UIColor)[[:space:]]+colorWithWhite:' || true)

  # R3 直写彩色必须包在动态 Provider 内
  if echo "$BODY" | grep -q 'colorWithRed'; then
    if ! echo "$BODY" | grep -q 'colorWithDynamicProvider'; then
      report "$f  —— 使用 colorWithRed:green:blue: 直写彩色，但同文件没有 colorWithDynamicProvider：深色模式下颜色不适配，请包进动态 Provider 按 userInterfaceStyle 分支（参照 PTEngineChain.m PTChainPillBG）"
    fi
  fi
done

# 防空转：扫描范围内没有任何 UIColor 痕迹 → 规则本身失效（文件被误删/改名/模式写错）
if [ "$COLOR_HITS" -eq 0 ]; then
  echo "check_darkmode: ✗ 扫描范围内未匹配到任何 UIColor 使用（规则失效？）" >&2
  exit 1
fi

if [ "$FAIL" -ne 0 ]; then
  echo "check_darkmode: ✗ 存在深色模式不安全配色（见上；安全色速查表见脚本头注释）" >&2
  exit 1
fi

echo "check_darkmode: OK（${SCANNED} 个 UI 文件扫描通过，无写死配色）"
exit 0
