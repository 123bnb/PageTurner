#!/usr/bin/env python3
# ============================================================
# transpile_subscript.py —— Linux 深度测试通道（v1.0.78，评审 #6）
#
# 用途：把 tests/PTCoreLogicTests.m 与 common/PTCoreLogic.m 的 ObjC 对象
# 下标机械改写为等价的显式消息，使「只有 clang + gnustep-base（legacy gcc
# runtime）」的 Linux 机器也能真跑测试断言（tests/run.sh 第三路径）。
# 产物写 tests/.build/transpiled/（.gitignore，不进版本控制）。
#
# 为什么需要：Linux clang 的 legacy(gcc) runtime 不支持对象下标
# （-fobjc-subscripting-legacy-runtime 自 LLVM 7 起是未接线的死旗），
# GCC 的 objc 头与 clang 内建 id 不兼容，典型发行版又缺 gnustep-2.0
# runtime 头 → 带下标语法的 ObjC 在 Linux 上编不了。改写后语义与编译器
# 展开完全一致：X[K] → [X objectForKeyedSubscript:K] /
# [X objectAtIndexedSubscript:(K)] / [X setObject:V forKeyedSubscript:K]。
# macOS/CI 路径不经过本脚本（原生支持下标，tests/run.sh 第一路径）。
#
# 架构：先剥注释（保行结构），再对「字符串掩码版」做括号匹配（掩码与原串
# 等长同位），base/key 文本从原串按位切片——匹配不受字符串干扰，输出保留
# 原文。迭代到不动点（嵌套下标逐层展开）。宁可报错不猜。
#
# 实现要点（都是踩过的坑）：
#   - ObjC 没有「括号外消息语法」，`X objectForKeyedSubscript:K` 不是合法
#     表达式 → 必须发完整括号形式 [X objectForKeyedSubscript:K]；
#   - 扫描器逐字输出，到达 '[' 时 base 已在 out 里 → 先把 base 从 out
#     「弹出」（rstrip 后按文本卸载），再发 [base 选择子:key]；
#   - 链式 X[A][B]：第二个下标的消息以第一个改写组为 receiver，必须嵌套
#     [[X ...A] ...B]，绝不能拍平成复合选择子 objectAtIndexedSubscript:
#     objectForKeyedSubscript:（不存在的方法，运行期 unrecognized selector）。
#     做法：记录刚发出组的 '[' 在 out 中的下标，链式时在其前插一个 '['
#     并在组尾后续新选择子，同一外层括号逐层向外扩；
#   - base 识别用 expr_start_back（标识符 + .-> + 平衡 []/() 组），
#     支持 x.foo(a)[0]、[foo bar][0]、PTFeaturesOfPlan(...)[0] 等复合基座；
#   - 附带字面量适配：@YES/@NO → @(1)/@(0)。GCC 系统头把 YES 定义成
#     (BOOL)1，clang 的 @( ) 装箱解析器不接受裸类型名开头（"unexpected
#     type name 'BOOL'"）；Apple 运行时无此问题。装箱数值语义等价。
#
# 维护须知：DICT_VARS/ARRAY_VARS/C_ARRAYS 三张变量表按「被测代码里出现
# 下标访问的变量」硬编码（用于判定 keyed/indexed/C 数组）。将来改了
# PTCoreLogic.m 或测试文件、引入新的下标变量时，若忘记更新表，本脚本会
# 以「无法分类的下标」响亮报错（不会静默改错）——届时把新变量补进对应
# 表即可。测试语义以 tests/PTCoreLogicTests.m 原文为准，改写只换语法。
# ============================================================
import re, sys, os

def adapt_literals(s):
    """沙箱专用字面量适配：@YES/@NO → @(1)/@(0)（整词边界，不碰 @NOxx 之类）。"""
    s = re.sub(r"@YES\b", "@(1)", s)
    s = re.sub(r"@NO\b", "@(0)", s)
    return s

KEYWORDS = {"return", "if", "for", "while", "switch", "sizeof", "else", "do",
            "case", "default", "goto", "break", "continue"}
DICT_VARS = {"gPlans", "cfg", "ft", "p", "a", "s", "d", "back", "back2", "sFakeCfg"}
ARRAY_VARS = {"plans", "same", "ts", "xs", "ys", "arr", "pts", "mem"}
C_ARRAYS = {"gLearnedSenders", "distsWide", "distsTight", "argv", "__argv", "envp"}

def strip_comments(s):
    out, i, n, state = [], 0, len(s), "code"
    while i < n:
        c, nxt = s[i], s[i+1] if i+1 < n else ""
        if state == "code":
            if c == "/" and nxt == "/":
                state = "line"; i += 2; continue
            if c == "/" and nxt == "*":
                state = "block"; i += 2; continue
            if c == '"':
                j = i + 1
                while j < n:
                    if s[j] == "\\":
                        j += 2; continue
                    if s[j] == '"':
                        break
                    j += 1
                out.append(s[i:j+1]); i = j + 1; continue
            if c == "'":
                j = i + 1
                while j < n and s[j] != "'":
                    j += 2 if s[j] == "\\" else 1
                j += 1
                out.append(s[i:j]); i = j; continue
            out.append(c); i += 1; continue
        if state == "line":
            if c == "\n":
                out.append("\n"); state = "code"
            else:
                out.append(" ")
            i += 1; continue
        if c == "*" and nxt == "/":
            out.append(" "); state = "code"; i += 2; continue
        out.append("\n" if c == "\n" else " "); i += 1; continue
    return "".join(out)

def mask_literals(s):
    """等长掩码：字符串/字符字面量内部 → 'x'（首尾引号保留），括号匹配不受干扰。"""
    out, i, n = list(s), 0, len(s)
    while i < n:
        c = out[i]
        if c == '"':
            j = i + 1
            while j < n:
                if out[j] == "\\":
                    out[j] = "x"; out[j+1] = "x"; j += 2; continue
                if out[j] == '"':
                    break
                out[j] = "x"; j += 1
            i = j + 1; continue
        if c == "'":
            j = i + 1
            while j < n and out[j] != "'":
                if out[j] == "\\":
                    out[j] = "x"; out[j+1] = "x"; j += 1
                out[j] = "x"; j += 1
            i = j + 1; continue
        i += 1
    return "".join(out)

def match_back(msk, j, opener, closer):
    """msk[j]==closer → 往前找匹配的 opener 索引。"""
    depth, i = 0, j
    while i >= 0:
        c = msk[i]
        if c == closer:
            depth += 1
        elif c == opener:
            depth -= 1
            if depth == 0:
                return i
        i -= 1
    raise SyntaxError(f"{closer} 无匹配 {opener}（偏移 {j}）")

def match_fwd(msk, i, opener, closer):
    """msk[i]==opener → 往后找匹配的 closer 索引。"""
    depth, j, n = 0, i, len(msk)
    while j < n:
        c = msk[j]
        if c == opener:
            depth += 1
        elif c == closer:
            depth -= 1
            if depth == 0:
                return j
        j += 1
    raise SyntaxError(f"{opener} 无匹配 {closer}（偏移 {i}）")

def prev_nonspace(s, i):
    j = i - 1
    while j >= 0 and s[j] in " \t\r\n":
        j -= 1
    return j

def is_ident_char(c):
    return c.isalnum() or c == "_"

def expr_start_back(msk, end):
    """从 end（含）往前扫完整表达式起点：标识符链 + .-> + 平衡的 []/() 组。"""
    j = end
    while j >= 0:
        if is_ident_char(msk[j]) or msk[j] in ".->":
            j -= 1
        elif msk[j] == "]":
            j = match_back(msk, j, "[", "]") - 1
        elif msk[j] == ")":
            j = match_back(msk, j, "(", ")") - 1
        else:
            break
    return j + 1

def base_start_ident(s, end):
    j = end
    while j >= 0 and (is_ident_char(s[j]) or s[j] in ".->"):
        j -= 1
    return j + 1

def one_pass(txt, msk):
    """把 X[K] 改写为 [X objectForKeyedSubscript:K]（等价的显式消息）。

    关键不变量：扫描器逐字输出，遇到候选 '[' 时其 base 已在 out 里——
    所以先把 base 从 out 弹出，再发完整括号形式。
    链式 X[A][B]：第二个下标的消息以第一个改写组为 receiver，必须嵌套——
    [[X objectForKeyedSubscript:A] objectForKeyedSubscript:B]，绝不能拍平
    成复合选择子（那是不存在的方法，运行期 unrecognized selector）。
    做法：记录刚发出组的 '[' 在 out 中的下标，链式时在其前插一个 '['
    并在组尾 ']' 后续新选择子——同一对外层括号逐层向外扩。
    """
    out, i, n = [], 0, len(txt)
    changed = False
    consumed_opens = set()   # 本轮已作为「改写起点」发出过的 '[' 位置
    last_group_idx = -1      # 刚发出的改写组的 '[' 在 out 文本中的下标
    while i < n:
        if msk[i] != "[":
            out.append(txt[i]); i += 1; continue
        pj = prev_nonspace(msk, i)
        if pj < 0 or not (is_ident_char(msk[pj]) or msk[pj] in ")]"):
            out.append(txt[i]); i += 1; continue
        # ')' 前邻校验：必须是调用（标识符紧邻 '('，且非关键字）或链式子下标（']' 紧邻 '('）
        if msk[pj] == ")":
            op = match_back(msk, pj, "(", ")")
            kk = prev_nonspace(msk, op)
            if kk >= 0 and is_ident_char(msk[kk]):
                cbs = base_start_ident(msk, kk)
                if re.split(r"[.\->]", txt[cbs:kk+1])[0] in KEYWORDS:
                    out.append(txt[i]); i += 1; continue   # if (/while (/for ( → 消息发送
            if kk < 0 or not (is_ident_char(msk[kk]) or msk[kk] == "]"):
                out.append(txt[i]); i += 1; continue   # 类型转换/括号表达式 → 消息发送
        # base 识别（只用于分类与弹出；文本从 out 卸载后原样重发）
        chained_consumed = False
        if is_ident_char(msk[pj]):
            bs = expr_start_back(msk, pj)
            base = txt[bs:pj+1]
            head = re.split(r"[.\->]", base)[0]
            if head in KEYWORDS:
                out.append(txt[i]); i += 1; continue
        elif msk[pj] == ")":
            op = match_back(msk, pj, "(", ")")
            kk = prev_nonspace(msk, op)
            if kk >= 0 and is_ident_char(msk[kk]):
                bs = expr_start_back(msk, kk)
                base = txt[bs:pj+1]
            else:
                base = txt[op:pj+1]
        else:  # ']' 链式
            lb = match_back(msk, pj, "[", "]")
            if lb in consumed_opens:
                chained_consumed = True
                base = ""
            else:
                bs = lb
                if bs > 0 and (is_ident_char(msk[bs-1]) or msk[bs-1] in ")]"):
                    bs = expr_start_back(msk, bs-1)
                base = txt[bs:pj+1]
        close = match_fwd(msk, i, "[", "]")
        key = txt[i+1:close].strip()
        # ---- 分类 ----
        if key.startswith('@"'):
            kind = "keyed"
        else:
            head = re.split(r"[.\->]", base)[0] if base else ""
            if head in C_ARRAYS:
                out.append(txt[i]); i += 1; continue
            if head in DICT_VARS:
                kind = "keyed"
            elif head in ARRAY_VARS or (base and base.lstrip().startswith("[")):
                kind = "indexed"
            elif base.endswith(")"):
                # 调用返回值下标（如 PTFeaturesOfPlan(...)[0]）：按键形态定型
                kind = "keyed" if key.startswith("@") else "indexed"
            elif chained_consumed:
                kind = "indexed"   # 链式已消费组的后续下标（本例未出现）
            else:
                raise SystemExit(f"✗ 无法分类的下标：base={base!r} key={key!r}（偏移 {i}）——请更新变量表")
        consumed_opens.add(i)
        # ---- 赋值检测 ----
        k = close + 1
        while k < n and msk[k] in " \t":
            k += 1
        is_assign = (k < n and msk[k] == "=" and not (k+1 < n and msk[k+1] == "="))
        if is_assign:
            depth, j = 0, k + 1
            while j < n:
                cj = msk[j]
                if cj in "([{":
                    depth += 1
                elif cj in ")]}":
                    depth -= 1
                elif cj == ";" and depth == 0:
                    break
                j += 1
            rhs = txt[k+1:j].strip()
            sel = "forKeyedSubscript:" if kind == "keyed" else "forIndexedSubscript:"
            if chained_consumed:
                # 嵌套：刚发出的组作 receiver，外再包一层 setObject 消息
                joined = "".join(out)
                assert 0 <= last_group_idx < len(joined) and joined[last_group_idx] == "[", \
                    f"链式赋值基线异常：idx={last_group_idx} tail={joined[-20:]!r}"
                out = [joined[:last_group_idx] + "[" + joined[last_group_idx:]
                       + f" setObject:{rhs} {sel}{key}]"]
            else:
                joined = "".join(out).rstrip()
                assert joined.endswith(base), f"赋值基线异常：{joined[-40:]!r} vs base={base!r}"
                out = [joined[:-len(base)]]
                last_group_idx = len(out[0])
                out.append(f"[{base} setObject:{rhs} {sel}{key}]")
            out.append(";")
            i = j + 1
            changed = True
            continue
        if chained_consumed:
            # 嵌套：组尾 ']' 后续新选择子，组首 '[' 前插一个 '['（同一位置，
            # 后续链式继续向外扩层；last_group_idx 保持不变）
            joined = "".join(out)
            assert 0 <= last_group_idx < len(joined) and joined[last_group_idx] == "[", \
                f"链式基线异常：idx={last_group_idx} tail={joined[-20:]!r}"
            if kind == "keyed":
                tail = f" objectForKeyedSubscript:{key}]"
            else:
                tail = f" objectAtIndexedSubscript:({key})]"
            out = [joined[:last_group_idx] + "[" + joined[last_group_idx:] + tail]
        else:
            joined = "".join(out).rstrip()
            assert joined.endswith(base), f"基线异常：{joined[-40:]!r} vs base={base!r}"
            out = [joined[:-len(base)]]
            last_group_idx = len(out[0])
            if kind == "keyed":
                out.append(f"[{base} objectForKeyedSubscript:{key}]")
            else:
                out.append(f"[{base} objectAtIndexedSubscript:({key})]")
        i = close + 1
        changed = True
    return "".join(out), changed

def transpile(src, max_iter=20):
    src = adapt_literals(strip_comments(src))
    for it in range(max_iter):
        msk = mask_literals(src)
        src, changed = one_pass(src, msk)
        if not changed:
            return src, it + 1
    raise SystemExit("✗ 下标改写未收敛")

def main():
    srcdir, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    for name in sys.argv[3:]:
        src = open(os.path.join(srcdir, name), encoding="utf-8").read()
        dst, iters = transpile(src)
        open(os.path.join(outdir, name), "w", encoding="utf-8").write(dst)
        print(f"  {name}: 下标改写完成（{iters} 轮不动点）")

if __name__ == "__main__":
    main()
