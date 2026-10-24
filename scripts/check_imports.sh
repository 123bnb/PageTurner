#!/usr/bin/env bash
# ============================================================
# check_imports.sh —— import 链静态校验（无需编译器）
# ============================================================
# 背景（v1.0.78，评审 #2）：v1.0.77 连炸 5 轮 CI，其中 4 轮是同一类错误——
#   .m 里用了某个工程类型（消息接收者 / 基类 / 协议 / 成员声明）却没 import 它的头：
#     · PTDragSortHelper 属性未 @class 前向声明（头文件侧）
#     · PTUIPlansVC→PTUIPlanVC、PTUIDebugLogVC→PTUILogContentVC、
#       PTUIFeaturesVC→PTUILearnVC、PTUIPlanVC→4 个页面（.m 侧，didSelect 打开子页）
#     · PTShimVC.m 三个共享 VC、PTDylibUI.m 三个共享 VC（dylib 侧，本地不可编才暴露）
#   裸 clang 的 dylib 构建本地跑不了 → 这类错误只有 CI 能发现，代价是每轮数分钟。
#   本脚本把该关前移到「clone Theos 之前」：纯文本分析，秒级完成。
#
# 规则：
#   · 工程类型 = 项目头文件里的 @interface/@protocol 且名字以 PT 开头（项目约定），
#     这样系统类（UIView/NSString…）永远不会误报。
#   · .m 中「使用」= 消息接收者 [PTX …]、类型声明 PTX *、基类 : PTX、
#     协议 <PTX>、@implementation PTX——任一处不在 import 闭包内即报错。
#   · .h 中只有「基类 / 协议」要求 import（属性用 @class 前向声明是合法的）。
#   · 闭包 = 该文件 #import 的工程头 + 这些头自己 import 的工程头（传递）。
#   · 同一文件内 @interface 声明的类型视为可用（私有类/类扩展）。
#
# 用法：bash scripts/check_imports.sh [文件...]   （缺省 = 仓库全部 tracked .m/.h）
# 退出码：0 = 全部通过；1 = 发现问题（逐条带 文件:行号 与缺失的头）
# ============================================================
set -uo pipefail

cd "$(dirname "$0")/.."

FILES=("$@")
if [ ${#FILES[@]} -eq 0 ]; then
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # 注意：不用 mapfile——macOS 的 /bin/bash 是 3.2，没有该内建
    # （v1.0.78-fix：CI macos-latest 上 mapfile 直接 command not found，
    # 空 FILES 又触发 set -u 的 unbound variable，整关白挂）。
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
  echo "check_imports: ✗ 未发现任何待检查文件（git ls-files/find 异常？）" >&2
  exit 1
fi

python3 - "${FILES[@]}" <<'PY'
import sys, re, os, collections

files = sys.argv[1:]
headers = [f for f in files if f.endswith('.h')]
sources = [f for f in files if f.endswith('.m')]

# ---------- 1. 工程头注册表：basename → 路径；PT 前缀类型名 → 头文件 ----------
hmap = {}
for h in headers:
    base = os.path.basename(h)
    if base in hmap and hmap[base] != h:
        print(f"check_imports: ✗ 工程头 basename 冲突 {base}: {hmap[base]} 与 {h}")
        sys.exit(1)
    hmap[base] = h

project_types = {}   # PT 类型名 -> 声明它的头文件
declared_in = collections.defaultdict(set)   # 头文件 -> 其中声明的 PT 类型
iface_re = re.compile(r'@interface\s+(PT[A-Za-z0-9_]*)')
proto_re = re.compile(r'@protocol\s+(PT[A-Za-z0-9_]*)')
for h in headers:
    t = open(h, encoding='utf-8', errors='replace').read()
    for m in iface_re.finditer(t):
        project_types.setdefault(m.group(1), h)
        declared_in[h].add(m.group(1))
    for m in proto_re.finditer(t):
        project_types.setdefault(m.group(1), h)
        declared_in[h].add(m.group(1))

if not project_types:
    if headers:
        # 有头文件却零 PT 类型 = 命名约定被破坏或发现机制异常，响亮失败
        print("check_imports: ✗ 发现工程头文件但零 PT 前缀类型（PT 命名约定被破坏？）")
        sys.exit(1)
    print("check_imports: 输入中没有工程头文件（只传了 .m？），无事可查")
    sys.exit(0)

# ---------- 2. 去注释去字符串（保留换行以维持行号） ----------
def strip_noise(src):
    out = []
    i, n = 0, len(src)
    state = 'code'
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ''
        if state == 'code':
            if c == '/' and nxt == '/':
                state = 'line'; i += 2; continue
            if c == '/' and nxt == '*':
                state = 'block'; i += 2; continue
            if c == '"':
                state = 'str'; i += 1; continue
            if c == "'":
                state = 'chr'; i += 1; continue
            out.append(c); i += 1; continue
        if state == 'line':
            if c == '\n':
                out.append('\n'); state = 'code'
            else:
                out.append(' ')
            i += 1; continue
        if state == 'block':
            if c == '*' and nxt == '/':
                out.append(' '); state = 'code'; i += 2; continue
            out.append('\n' if c == '\n' else ' ')
            i += 1; continue
        if state == 'str':
            if c == '\\':
                i += 2; continue
            if c == '"':
                state = 'code'
            i += 1; continue
        if state == 'chr':
            if c == '\\':
                i += 2; continue
            if c == "'":
                state = 'code'
            i += 1; continue
    return ''.join(out)

# ---------- 3. import 闭包 ----------
import_re = re.compile(r'#import\s*[<"]([^">]+)[">]')
file_imports = {}    # 文件 -> 直接 import 的工程头集合
for f in headers + sources:
    src = open(f, encoding='utf-8', errors='replace').read()
    direct = set()
    for m in import_re.finditer(src):
        base = os.path.basename(m.group(1))
        if base in hmap:
            direct.add(hmap[base])
    file_imports[f] = direct

def closure(start):
    seen, queue = set(), list(start)
    while queue:
        h = queue.pop()
        if h in seen:
            continue
        seen.add(h)
        for nxt in file_imports.get(h, ()):
            if nxt not in seen:
                queue.append(nxt)
    return seen

def available_types(start_headers):
    """import 闭包内所有工程头里声明的 PT 类型名集合（不是路径！）"""
    types = set()
    for h in closure(start_headers):
        types |= declared_in.get(h, set())
    return types

# ---------- 4. 使用点提取 ----------
def used_types(clean):
    """返回 [(行号, 类型名, 形态)]"""
    hits = []
    # 形态 A：消息接收者 [PTX …]（含 [[PTX alloc] init] 嵌套，逐个匹配即可）
    for m in re.finditer(r'\[(PT[A-Za-z0-9_]+)\s', clean):
        hits.append((m.start(1), m.group(1), '消息接收者'))
    # 形态 B：类型声明/成员 PTX *（含 __kindof、property、函数参数、静态全局）
    for m in re.finditer(r'\b(PT[A-Za-z0-9_]+)\s*\*', clean):
        hits.append((m.start(1), m.group(1), '类型声明'))
    # 形态 C：基类 @interface/@implementation X : PTX
    for m in re.finditer(r'@(?:interface|implementation)\s+\w+\s*:\s*(PT[A-Za-z0-9_]+)', clean):
        hits.append((m.start(1), m.group(1), '基类'))
    # 形态 D：协议一致性 <…> 里的 PT 协议（含 id<PTX>）
    for m in re.finditer(r'<([^<>]*)>', clean):
        for name in re.split(r'[,\s]+', m.group(1)):
            if re.fullmatch(r'PT[A-Za-z0-9_]+', name or ''):
                hits.append((m.start(1), name, '协议'))
    # 形态 E：@implementation PTX（分类/类实现，自己就是使用点）
    for m in re.finditer(r'@implementation\s+(PT[A-Za-z0-9_]+)', clean):
        hits.append((m.start(1), m.group(1), '类实现'))
    return hits

def lineno(text, pos):
    return text.count('\n', 0, pos) + 1

errors = []
checked = 0
for f in sources + headers:
    raw = open(f, encoding='utf-8', errors='replace').read()
    clean = strip_noise(raw)
    own_declared = set(re.findall(r'@interface\s+(PT[A-Za-z0-9_]+)', clean)) \
                 | set(re.findall(r'@protocol\s+(PT[A-Za-z0-9_]+)', clean))
    avail = available_types(file_imports[f]) | own_declared
    is_source = f.endswith('.m')
    for pos, name, kind in used_types(clean):
        # .h 只强制基类/协议/类实现；属性/成员的 @class 前向声明合法
        if not is_source and kind in ('消息接收者', '类型声明'):
            continue
        if name in avail:
            continue
        want = project_types.get(name)
        if want is None:
            continue     # PT 前缀但项目里没有这个类型（外部/系统扩展），不猜
        errors.append(f"{f}:{lineno(clean, pos)}: 使用 {name}（{kind}）但未 import <{want}>")
    checked += 1

if errors:
    # 同文件同行去重，保持稳定输出
    seen, uniq = set(), []
    for e in errors:
        if e not in seen:
            seen.add(e); uniq.append(e)
    print(f"check_imports: 发现 {len(uniq)} 处缺失 import：")
    for e in uniq:
        print(f"  ✗ {e}")
    sys.exit(1)
print(f"check_imports: OK（{checked} 个文件，{len(project_types)} 个工程类型，import 链完整）")
PY
