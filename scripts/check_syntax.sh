#!/usr/bin/env bash
# ============================================================
# check_syntax.sh —— 源码括号平衡 / 结构静态校验（无需编译器）
# ============================================================
# 背景（v1.0.78，评审 #2）：v1.0.77 连炸 3 轮 CI 都是**语法级错误**
#   · PTUIPlanVC.m 两处「取消」按钮少一个 ]
#   · PTUILearnVC.m 两处 doubleValue]] 少一个 ]（嵌套 s[] 取值）
# 当时的校验脚本是「用完即弃」的临时工，没进仓库 → 下一次重构还得从零写。
# 本脚本把该关固化：字符级扫描（字符串/注释/字符字面量感知），
# 检查 () [] {} 的配对与嵌套；另加一项全仓结构检查：
#   · 同一类名不得有多份 @implementation（重复实现 = 链接期重复符号，
#     这正是本项目 v1.0.77 之前 9 个设置页两份实现的历史病根）
#
# 用法：bash scripts/check_syntax.sh [文件...]   （缺省 = 仓库全部 tracked .m/.h）
# 退出码：0 = 全部通过；1 = 发现问题（逐条带 文件:行号）
# ============================================================
set -uo pipefail

cd "$(dirname "$0")/.."

FILES=("$@")
if [ ${#FILES[@]} -eq 0 ]; then
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # 注意：不用 mapfile——macOS 的 /bin/bash 是 3.2，没有该内建
    # （v1.0.78-fix：CI macos-latest 上 mapfile command not found，本关
    # 曾以「没有待检查文件」退出 0 假绿——静默跳过比挂更糟）。
    FILES=()
    while IFS= read -r f; do FILES+=("$f"); done < <(git ls-files '*.m' '*.h')
  else
    FILES=()
    while IFS= read -r f; do FILES+=("$f"); done < <(find . -path ./.git -prune -o -path ./.theos -prune -o \
      -path ./packages -prune -o -path ./out -prune -o -path ./.pt-version-snapshot -prune -o \
      -name '*.[mh]' -print | sed 's|^\./||')
  fi
fi

# 空文件列表 = 发现机制坏了（不是「没文件可查」）——必须响亮失败，
# 绝不静默跳过（v1.0.78-fix：CI 上假绿比挂更糟）。
if [ ${#FILES[@]} -eq 0 ]; then
  echo "check_syntax: ✗ 未发现任何待检查文件（git ls-files/find 异常？）" >&2
  exit 1
fi

python3 - "${FILES[@]}" <<'PY'
import sys, re

OPENERS = {'(': ')', '[': ']', '{': '}'}
CLOSERS = {v: k for k, v in OPENERS.items()}

def scan_brackets(path):
    """字符级扫描：跳过注释与字符串后做括号配对。返回错误列表。"""
    try:
        src = open(path, encoding='utf-8', errors='replace').read()
    except OSError as e:
        return [f"{path}: 读取失败: {e}"]
    errors = []
    stack = []          # (开括号字符, 行号)
    state = 'code'      # code / line_comment / block_comment / string / char
    i, n, line = 0, len(src), 1
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ''
        if c == '\n':
            line += 1
            if state == 'line_comment':
                state = 'code'
            i += 1
            continue
        if state == 'code':
            if c == '/' and nxt == '/':
                state = 'line_comment'; i += 2; continue
            if c == '/' and nxt == '*':
                state = 'block_comment'; i += 2; continue
            if c == '"':                       # ObjC @"..." 的引号部分同样处理
                state = 'string'; i += 1; continue
            if c == "'":
                state = 'char'; i += 1; continue
            if c in OPENERS:
                stack.append((c, line)); i += 1; continue
            if c in CLOSERS:
                if not stack:
                    errors.append(f"{path}:{line}: 多余的右括号 '{c}'（没有对应的开括号）")
                else:
                    o, ol = stack.pop()
                    if o != CLOSERS[c]:
                        errors.append(f"{path}:{line}: 括号类型不匹配——遇到 '{c}'，"
                                      f"但最近未闭合的是第 {ol} 行的 '{o}'")
                i += 1; continue
            i += 1; continue
        if state == 'line_comment':
            i += 1; continue
        if state == 'block_comment':
            if c == '*' and nxt == '/':
                state = 'code'; i += 2; continue
            i += 1; continue
        if state == 'string':
            if c == '\\':
                i += 2; continue
            if c == '"':
                state = 'code'; i += 1; continue
            i += 1; continue
        if state == 'char':
            if c == '\\':
                i += 2; continue
            if c == "'":
                state = 'code'; i += 1; continue
            i += 1; continue
    if state == 'block_comment':
        errors.append(f"{path}: 块注释 /* ... */ 未闭合")
    if state == 'string':
        errors.append(f"{path}: 字符串字面量未闭合（缺少收尾引号）")
    for o, ol in stack:
        errors.append(f"{path}:{ol}: 开括号 '{o}' 从未闭合")
    return errors

def strip_noise(src):
    """去注释去字符串（保留换行以维持行号），供结构检查用。"""
    s = re.sub(r'//[^\n]*', ' ', src)
    s = re.sub(r'/\*.*?\*/', ' ', s, flags=re.S)
    s = re.sub(r'"(?:\\.|[^"\\])*"', '""', s)
    return s

files = sys.argv[1:]
all_errors = []
for f in files:
    if f.endswith('.m') or f.endswith('.h'):
        all_errors += scan_brackets(f)

# 全仓级别的重复 @implementation 检查（同名类只能有一份实现，否则链接期重复符号）
impl_names = {}
for f in files:
    if not f.endswith('.m'):
        continue
    cleaned = strip_noise(open(f, encoding='utf-8', errors='replace').read())
    for m in re.finditer(r'@implementation\s+([A-Za-z_]\w*)', cleaned):
        impl_names.setdefault(m.group(1), []).append(f)
for name, fs in sorted(impl_names.items()):
    if len(fs) > 1:
        all_errors.append(f"重复 @implementation {name}（{len(fs)} 份，链接期重复符号）：{', '.join(fs)}")

if all_errors:
    print(f"check_syntax: 发现 {len(all_errors)} 处问题：")
    for e in all_errors:
        print(f"  ✗ {e}")
    sys.exit(1)
print(f"check_syntax: OK（{len(files)} 个文件，括号平衡 / 无重复实现）")
PY
