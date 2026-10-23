// ============================================================
// PTDragSortHelper.m —— 长按拖拽排序助手实现（v1.0.77）
//
// 合并自 deb 两份逐字复制的实现（v1.0.66 #5 / #5b）：
//   · 方案列表页 planLongPress：手势装表格，Began 即建快照进拖拽
//   · 方案页 longPressAction（Z 方案）：手势装 cell，Began 只记录，
//     Changed 过 10pt 阈值才建快照进拖拽；未拖动（长按不动）→ Ended 回调
//     onLongPressStill（进参数页）
// dylib 侧原本用右上角「排序」+ 系统编辑态手柄（canMoveRow/moveRow），
// 统一后删除，与 deb 交互完全一致。
// ============================================================
#import "PTDragSortHelper.h"

@interface PTDragSortHelper ()
@property (nonatomic, weak) UITableView *tv;
@property (nonatomic, assign) PTDragAttachMode mode;
@property (nonatomic, strong) UIView *snap;
@property (nonatomic, assign) NSInteger dragFrom;
@property (nonatomic, assign) NSInteger dragRow;
@property (nonatomic, assign) BOOL didDrag;
@property (nonatomic, assign) CGPoint startPt;
@property (nonatomic, assign) BOOL justDraggedFlag;
@end

@implementation PTDragSortHelper

- (instancetype)initWithTableView:(UITableView *)tv mode:(PTDragAttachMode)mode {
    self = [super init];
    if (self) {
        _tv = tv;
        _mode = mode;
        _dragFrom = -1;
        _dragRow = -1;
        _didDrag = NO;
        _justDraggedFlag = NO;
    }
    return self;
}

- (BOOL)justDragged { return _justDraggedFlag; }

- (BOOL)consumeJustDragged {
    BOOL v = _justDraggedFlag;
    _justDraggedFlag = NO;
    return v;
}

// table 模式：长按手势装整个表格（viewDidLoad 调一次）
- (void)attachToTable {
    if (self.mode != PTDragAttachTable) return;
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    [self.tv addGestureRecognizer:lp];
}

// cells 模式：每个 cell 挂一个（先去重，防 cell 复用叠手势）
- (void)attachToCell:(UITableViewCell *)cell {
    if (!cell) return;
    for (UIGestureRecognizer *g in cell.gestureRecognizers)
        if ([g isKindOfClass:[UILongPressGestureRecognizer class]]) [cell removeGestureRecognizer:g];
    UILongPressGestureRecognizer *lg = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    [cell addGestureRecognizer:lg];
}

// 该行是否可拖（nil 块=全部可拖）
- (BOOL)rowCanDrag:(NSInteger)row {
    if (self.canDragRow) return self.canDragRow(row);
    return YES;
}

- (void)resetDragState {
    for (UITableViewCell *c in self.tv.visibleCells) c.hidden = NO;
    [self.snap removeFromSuperview];
    self.snap = nil;
    self.dragFrom = -1;
    self.dragRow = -1;
    self.didDrag = NO;
}

// 拖拽中的实时换序（两侧逐字一致）：移动 items + moveRow + 隐藏当前行
- (void)moveToRow:(NSInteger)t {
    if (t < 0) t = 0;
    NSInteger maxRow = (NSInteger)self.items.count - 1;
    if (maxRow < 0) return;
    if (t > maxRow) t = maxRow;   // 落点钳制：不拖到「新增」行之后
    if (t != self.dragRow) {
        id obj = self.items[self.dragRow];
        NSMutableArray *m = [NSMutableArray arrayWithArray:self.items];
        [m removeObjectAtIndex:self.dragRow];
        if (t < (NSInteger)m.count) [m insertObject:obj atIndex:t];
        else [m addObject:obj];
        self.items = m;
        [self.tv moveRowAtIndexPath:[NSIndexPath indexPathForRow:self.dragRow inSection:0]
                      toIndexPath:[NSIndexPath indexPathForRow:t inSection:0]];
        self.dragRow = t;
    }
    // 先全显再隐藏当前行，避免 cell 复用残留 hidden（v1.0.66 #5b 修的串隐 bug）
    for (UITableViewCell *c in self.tv.visibleCells) c.hidden = NO;
    UITableViewCell *cur = [self.tv cellForRowAtIndexPath:[NSIndexPath indexPathForRow:self.dragRow inSection:0]];
    if (cur) cur.hidden = YES;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (self.mode == PTDragAttachTable) {
        [self handleTableMode:g];
    } else {
        [self handleCellsMode:g];
    }
}

// ---------- 模式一：方案列表页（Began 即拖） ----------
- (void)handleTableMode:(UILongPressGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.tv];
    if (g.state == UIGestureRecognizerStateBegan) {
        NSIndexPath *ip = [self.tv indexPathForRowAtPoint:p];
        if (!ip || ip.row >= (NSInteger)self.items.count || ![self rowCanDrag:ip.row]) {
            self.dragFrom = -1; self.dragRow = -1; return;
        }
        self.dragFrom = ip.row; self.dragRow = ip.row;
        UITableViewCell *cell = [self.tv cellForRowAtIndexPath:ip];
        if (!cell) { self.dragFrom = -1; return; }
        self.snap = [cell snapshotViewAfterScreenUpdates:NO];
        self.snap.frame = cell.frame;
        [self.tv addSubview:self.snap];
        cell.hidden = YES;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        if (self.dragFrom < 0) return;
        self.snap.center = CGPointMake(self.tv.bounds.size.width / 2.0, p.y);
        NSIndexPath *target = [self.tv indexPathForRowAtPoint:p];
        NSInteger t = target ? target.row : (NSInteger)self.items.count - 1;
        [self moveToRow:t];
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        if (self.dragFrom < 0) return;
        NSArray *ordered = self.items;
        [self resetDragState];
        if (self.onReorder) self.onReorder(ordered);
        self.justDraggedFlag = YES;   // 抑制松手误触（列表页 didSelect 防抖）
    }
}

// ---------- 模式二：方案页动作行（Z 方案：点按=编辑、长按不动=参数页、长按拖动=排序） ----------
- (void)handleCellsMode:(UILongPressGestureRecognizer *)g {
    UITableViewCell *cell = (UITableViewCell *)g.view;
    if (g.state == UIGestureRecognizerStateBegan) {
        self.didDrag = NO;
        self.justDraggedFlag = NO;
        self.dragFrom = -1; self.dragRow = -1;
        NSIndexPath *ip = [self.tv indexPathForCell:cell];
        if (!ip || ip.row >= (NSInteger)self.items.count) return;
        if (![self rowCanDrag:ip.row]) {
            if (self.onDragRejected) self.onDragRejected(ip.row);   // 废案动作等：调用方提示
            return;
        }
        self.dragFrom = ip.row; self.dragRow = ip.row;
        self.startPt = [g locationInView:self.tv];
        // 不立即建快照：先等 Changed 判断是否真拖动；未拖动(长按不动)才在 Ended 走 onLongPressStill
    } else if (g.state == UIGestureRecognizerStateChanged) {
        if (self.dragFrom < 0) return;
        CGPoint now = [g locationInView:self.tv];
        if (!self.didDrag) {
            CGFloat dx = now.x - self.startPt.x, dy = now.y - self.startPt.y;
            if (hypot(dx, dy) < 10.0) return;   // 未超阈值：仍算「长按不动」，不进拖拽
            self.didDrag = YES;
            UITableViewCell *c = [self.tv cellForRowAtIndexPath:[NSIndexPath indexPathForRow:self.dragRow inSection:0]];
            if (c) {
                self.snap = [c snapshotViewAfterScreenUpdates:NO];
                self.snap.frame = c.frame;
                [self.tv addSubview:self.snap];
                c.hidden = YES;
            }
        }
        if (!self.snap) return;   // 极端：当前 cell 不可见导致快照没建成，放弃本次拖拽
        self.snap.center = CGPointMake(self.tv.bounds.size.width / 2.0, now.y);
        NSIndexPath *target = [self.tv indexPathForRowAtPoint:now];
        NSInteger t = target ? target.row : (NSInteger)self.items.count - 1;
        [self moveToRow:t];
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        if (self.dragFrom < 0) return;
        if (self.didDrag) {
            NSArray *ordered = self.items;
            [self resetDragState];
            if (self.onReorder) self.onReorder(ordered);
            self.justDraggedFlag = YES;   // 防止松手瞬间被误判为点按进编辑页
        } else {
            // 长按不动 → 进参数页（调用方实现）
            NSInteger r = self.dragFrom;
            self.dragFrom = -1; self.dragRow = -1;
            if (self.onLongPressStill && r >= 0 && r < (NSInteger)self.items.count) self.onLongPressStill(r);
        }
    }
}

@end
