#!/usr/bin/env bash
# ============================================================
# tests/run.sh —— PTCoreLogic 纯逻辑测试入口（v1.0.78，评审 #6）
#
# 背景：引擎六个实现文件都 import UIKit，macOS 上编不了 → CI（macos-latest）
# 原本跑不了任何单测。v1.0.78 把零 UI 依赖的纯逻辑下沉为
# common/PTCoreLogic.{h,m}（Foundation/CoreGraphics-only），本脚本只链它：
#   · macOS（CI 路径，强制）：clang -framework Foundation -framework CoreGraphics，
#     ARC + 现代 ObjC 语法（对象下标等）原生可用。
#   · Linux 路径 A（gnustep-2.0 完整通道）：机器装有 libobjc2（gnustep-2.0
#     runtime 头在位）时，ARC + 对象下标原生可用——先用 5 行探针验证，
#     通过则直接完整构建。
#   · Linux 路径 B（下标改写降级通道）：只有 clang + gnustep-base（legacy
#     gcc runtime）时，探针必然失败（clang 的 legacy runtime 不支持对象下标，
#     -fobjc-subscripting-legacy-runtime 自 LLVM 7 起是未接线的死旗；GCC 的
#     objc 头与 clang 内建 id 也不兼容）。此时用 tests/transpile_subscript.py
#     把对象下标机械改写为等价的显式消息（[X objectForKeyedSubscript:K] 等，
#     语义与编译器展开一致），关 ARC 走 gcc runtime 编译——断言照跑。
#     CoreGraphics 用最小垫片（PTCoreLogic 只用到 CGPoint 三件套）；
#     NSPropertyList 头 GNUstep 的 Foundation.h 不聚合，用 -include 注入。
#     垫片与 -include 只影响本机测试编译。
#   · 连 clang/GNUstep 都没有：SKIP，退出码 0（不阻塞 CI 其他关卡；
#     CI 必跑 macOS 路径）。
#
# 退出码：0 = 通过/跳过；1 = 编译失败或断言失败。
# 用法：bash tests/run.sh
# ============================================================
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD_DIR="tests/.build"
OUT="$BUILD_DIR/PTCoreLogicTests"
mkdir -p "$BUILD_DIR"

OS="$(uname -s)"
if [ "$OS" = "Darwin" ]; then
    # ---------- macOS：原生框架，CI 实际跑的路径 ----------
    echo "tests/run.sh: macOS 原生编译（Foundation + CoreGraphics，ARC）"
    clang -fobjc-arc -framework Foundation -framework CoreGraphics \
        -I"$ROOT/common" \
        "$ROOT/tests/PTCoreLogicTests.m" "$ROOT/common/PTCoreLogic.m" \
        -o "$OUT" || exit 1
else
    # ---------- Linux：先探针（gnustep-2.0），失败降级下标改写通道 ----------
    if ! command -v clang >/dev/null 2>&1 || ! command -v gnustep-config >/dev/null 2>&1; then
        echo "tests/run.sh: SKIP（非 macOS 且缺 clang/GNUstep——纯逻辑测试只在 CI macos-latest 强制跑）"
        exit 0
    fi
    echo "tests/run.sh: Linux 路径——先探针验证 gnustep-2.0 + ARC + 对象下标"
    cat > "$BUILD_DIR/probe.m" <<'EOF'
#import <Foundation/Foundation.h>
int main(void) {
    @autoreleasepool {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"k"] = @"v";
        NSLog(@"%@", d[@"k"]);
    }
    return 0;
}
EOF
    if clang -fobjc-arc -fobjc-runtime=gnustep-2.0 $(gnustep-config --objc-flags) \
            "$BUILD_DIR/probe.m" -o "$BUILD_DIR/probe" $(gnustep-config --base-libs) 2>/dev/null \
            && "$BUILD_DIR/probe" >/dev/null 2>&1; then
        echo "tests/run.sh: 探针通过——gnustep-2.0 完整构建（ARC + 对象下标原生可用）"
        # CoreGraphics 垫片（PTCoreLogic 只用到 CGPoint 三件套）
        SHIM="$BUILD_DIR/shim/CoreGraphics"
        mkdir -p "$SHIM"
        cat > "$SHIM/CoreGraphics.h" <<'EOF'
// Linux/GNUstep 测试垫片：PTCoreLogic 只用到 CGPoint 三件套
// （macOS 路径用真 CoreGraphics framework，无需此文件）
#ifndef PTShimCoreGraphics_h
#define PTShimCoreGraphics_h
typedef double CGFloat;
typedef struct CGPoint { CGFloat x; CGFloat y; } CGPoint;
typedef struct CGSize { CGFloat width; CGFloat height; } CGSize;
typedef struct CGRect { CGPoint origin; CGSize size; } CGRect;
static inline CGPoint CGPointMake(CGFloat x, CGFloat y) {
    CGPoint p; p.x = x; p.y = y; return p;
}
#define CGPointZero ((CGPoint){0, 0})
static inline int CGPointEqualToPoint(CGPoint a, CGPoint b) {
    return a.x == b.x && a.y == b.y;
}
#endif
EOF
        clang -fobjc-arc -fobjc-runtime=gnustep-2.0 $(gnustep-config --objc-flags) \
            -include Foundation/NSPropertyList.h \
            -I"$BUILD_DIR/shim" -I"$ROOT/common" \
            "$ROOT/tests/PTCoreLogicTests.m" "$ROOT/common/PTCoreLogic.m" \
            -o "$OUT" $(gnustep-config --base-libs) || exit 1
    else
        # ---------- Linux 路径 B：下标改写 + legacy(gcc) runtime ----------
        # 探针失败的典型原因：只装了 gnustep-base 没装 libobjc2。不冒充
        # 通过也不空手而归——把对象下标改写为等价显式消息后关 ARC 编译，
        # 断言照常执行（tests/transpile_subscript.py，产物进 .build，勿提交）。
        echo "tests/run.sh: 探针失败（缺 gnustep-2.0 runtime 头/ARC/对象下标）——降级下标改写通道"
        if ! command -v python3 >/dev/null 2>&1; then
            echo "tests/run.sh: SKIP（无 python3，无法运行下标改写器）"
            exit 0
        fi
        # GCC runtime 的 objc 头目录（版本号随发行版变化，动态解析）
        GCCINC="$(gcc -print-file-name=include 2>/dev/null || true)"
        if [ -z "$GCCINC" ] || [ ! -f "$GCCINC/objc/objc.h" ]; then
            OBJC_H="$(find /usr/lib/gcc /usr/include -name objc.h -path '*/objc/*' 2>/dev/null | head -1)"
            [ -n "$OBJC_H" ] && GCCINC="$(dirname "$(dirname "$OBJC_H")")"
        fi
        if [ -z "$GCCINC" ] || [ ! -f "$GCCINC/objc/objc.h" ]; then
            echo "tests/run.sh: SKIP（找不到 GCC runtime 的 objc 头；装 gcc/objc 运行时后再试）"
            exit 0
        fi
        SHIM="$BUILD_DIR/shim/CoreGraphics"
        mkdir -p "$SHIM"
        cat > "$SHIM/CoreGraphics.h" <<'EOF'
// Linux/GNUstep 测试垫片：PTCoreLogic 只用到 CGPoint 三件套
#ifndef PTShimCoreGraphics_h
#define PTShimCoreGraphics_h
typedef double CGFloat;
typedef struct CGPoint { CGFloat x; CGFloat y; } CGPoint;
typedef struct CGSize { CGFloat width; CGFloat height; } CGSize;
typedef struct CGRect { CGPoint origin; CGSize size; } CGRect;
static inline CGPoint CGPointMake(CGFloat x, CGFloat y) {
    CGPoint p; p.x = x; p.y = y; return p;
}
#define CGPointZero ((CGPoint){0, 0})
static inline int CGPointEqualToPoint(CGPoint a, CGPoint b) {
    return a.x == b.x && a.y == b.y;
}
#endif
EOF
        TP="$BUILD_DIR/transpiled"
        mkdir -p "$TP"
        python3 "$ROOT/tests/transpile_subscript.py" "$ROOT/common" "$TP" PTCoreLogic.m || exit 1
        python3 "$ROOT/tests/transpile_subscript.py" "$ROOT/tests" "$TP" PTCoreLogicTests.m || exit 1
        echo "tests/run.sh: 下标改写完成——gcc runtime 编译（关 ARC）"
        # 注：-fno-objc-arc（legacy runtime 不支持 ARC）；短命测试进程，
        # 未接管的内存由进程退出回收，不影响断言结果。
        # -L 指向 GCC 自己的目录：libobjc.so 只在那里有 dev 链接名
        # （gnustep-config --base-libs 带 -lobjc 但不带这条 -L）。
        clang -fno-objc-arc -fobjc-runtime=gcc \
            -I"$GCCINC" -I"$ROOT/common" -I"$BUILD_DIR/shim" \
            $(gnustep-config --objc-flags) -include Foundation/NSPropertyList.h \
            "$TP/PTCoreLogicTests.m" "$TP/PTCoreLogic.m" \
            -o "$OUT" -L"$(dirname "$GCCINC")" $(gnustep-config --base-libs) || exit 1
    fi
fi

"$OUT"
