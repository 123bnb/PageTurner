//
//  PTFakeMetaTouch.h
//  PTFakeTouch
//
//  Created by PugaTang on 16/4/20.
//  Copyright © 2016年 PugaTang. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface PTFakeMetaTouch : NSObject
/**
 *  Fake a touch event 构造一个触屏基础操作
 *
 *  @param pointId 触屏操作的序列号
 *  @param point   操作的目的位置
 *  @param phase   操作的类别
 *
 *  @return pointId 返回操作的序列号
 */
+ (NSInteger)fakeTouchId:(NSInteger)pointId AtPoint:(CGPoint)point withTouchPhase:(UITouchPhase)phase;
/**
 *  Get a not used pointId 获取一个没有使用过的触屏序列号
 *
 *  @return pointId 返回序列号
 */
+ (NSInteger)getAvailablePointId;

/**
 * 判断一个 UITouch 是否是本类注入的假触摸（来自内部 touchAry 池）。
 * v1.0.66-fix：飞快势途中，引擎需在 sendEvent 里区分"本次注入的假触摸(放行给 App)"
 * 与"用户新按的真实翻页器触摸(放行去匹配以支持连滑/中断)"。
 */
+ (BOOL)isPoolTouch:(UITouch *)touch;

@end
