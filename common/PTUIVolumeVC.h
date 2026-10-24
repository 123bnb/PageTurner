// ============================================================
// PTUIVolumeVC.h —— 音量键模式页（v1.0.80）
//
// 独立页（方案页代码零改动的定稿方案）：总开关 + 音量+ 绿区 / 音量- 红区 +
// 底部唯一测试行。数据走 plans[] 里两个 volSource 特殊方案（懒创建空壳），
// 与翻页器方案同一模型、同一条执行链。
// ============================================================
#ifndef PTUIVolumeVC_h
#define PTUIVolumeVC_h

#import "PTUIBaseListVC.h"

@class PTDragSortHelper;

@interface PTUIVolumeVC : PTUIBaseListVC <UITableViewDataSource, UITableViewDelegate>

// 两个独立 table（各挂一个拖拽助手——helper 写死 section 0，单区表专用；
// 两区各一个表 = 天然不跨区混排）
@property (nonatomic, strong) UITableView *tv2;
@property (nonatomic, strong) PTDragSortHelper *dragUp;    // 音量+ 区拖拽
@property (nonatomic, strong) PTDragSortHelper *dragDown;  // 音量- 区拖拽

// 两区动作（reload 时从配置读出）
@property (nonatomic, strong) NSMutableArray *upActions;
@property (nonatomic, strong) NSMutableArray *downActions;

@end

#endif  // PTUIVolumeVC_h
