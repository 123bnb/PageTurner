// ============================================================
// PTDragSortHelper.h —— 长按拖拽排序助手（v1.0.77）
//
// 从两份逐字复制的实现抽出：
//   · deb 方案列表页 PTPlansVC 的 planLongPress（v1.0.66 #5，长按方案行拖拽）
//   · deb 方案页 PTPlanVC 的 longPressAction（v1.0.66 #5b，「Z 方案」：
//     点按=编辑、长按不动=参数页、长按并拖动=排序，~70 行状态机）
// dylib 侧原本没有拖拽（用右上角「排序」+系统编辑态手柄）——本版统一为 deb 的
// 长按拖拽交互（零三横线、无后遗症），dylib 的 toggleEdit/canMoveRow 等删除。
//
// 两种挂载模式：
//   · PTDragAttachTable：长按手势装在整个表格上（方案列表页；行由
//     indexPathForRowAtPoint 解析）
//   · PTDragAttachCells：长按手势装在每个 cell 上（方案页动作行；cellForRow
//     里对每个 cell 调 attachToCell:，内部先去重再挂）
// ============================================================
#ifndef PTDragSortHelper_h
#define PTDragSortHelper_h

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, PTDragAttachMode) {
    PTDragAttachTable,    // 手势装表格（方案列表页）
    PTDragAttachCells,    // 手势装 cell（方案页动作行）
};

@interface PTDragSortHelper : NSObject

- (instancetype)initWithTableView:(UITableView *)tv mode:(PTDragAttachMode)mode;

// 当前数据（拖拽中内部重排；松手经 onReorder 回写——调用方在其内重新赋值自己的数组）
@property (nonatomic, copy) NSArray *items;
@property (nonatomic, copy) void (^onReorder)(NSArray *orderedItems);
// 该行是否参与拖拽（NO=排除，如末行「新增方案」「新增映射」）；nil=全部可拖
@property (nonatomic, copy) BOOL (^canDragRow)(NSInteger row);
// canDragRow 返回 NO 时回调（调用方自行提示，如废案动作弹窗）；nil=静默排除
@property (nonatomic, copy) void (^onDragRejected)(NSInteger row);
// 长按未拖动（仅 cells 模式有意义：方案页=进参数页）；nil=无此行为
@property (nonatomic, copy) void (^onLongPressStill)(NSInteger row);
// 刚拖完排序（松手瞬间置 YES）：调用方在 didSelectRow 开头调 consumeJustDragged
// 抑制「松手误触进编辑页」
@property (nonatomic, readonly) BOOL justDragged;

- (void)attachToTable;                        // table 模式：装长按手势（viewDidLoad 调一次）
- (void)attachToCell:(UITableViewCell *)cell; // cells 模式：cellForRow 里对每个 cell 调
- (BOOL)consumeJustDragged;                   // 返回是否刚拖完（并清零）

@end

#endif  // PTDragSortHelper_h
