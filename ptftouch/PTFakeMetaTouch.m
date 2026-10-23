//
//  PTFakeMetaTouch.m
//  PTFakeTouch
//
//  Created by PugaTang on 16/4/20.
//  Copyright © 2016年 PugaTang. All rights reserved.
//

#import "PTFakeMetaTouch.h"
#import "UITouch-KIFAdditions.h"
#import "UIApplication-KIFAdditions.h"
#import "UIEvent+KIFAdditions.h"
#ifndef DLog
#define DLog(...) NSLog(__VA_ARGS__)
#endif
static NSMutableArray *touchAry;
@implementation PTFakeMetaTouch

+ (void)load{
    KW_ENABLE_CATEGORY(UITouch_KIFAdditions);
    KW_ENABLE_CATEGORY(UIEvent_KIFAdditions);
    touchAry = [[NSMutableArray alloc] init];
    for (NSInteger i = 0; i<100; i++) {
        UITouch *touch = [[UITouch alloc] initTouch];
        [touch setPhaseAndUpdateTimestamp:UITouchPhaseEnded];
        [touchAry addObject:touch];
    }
}

+ (NSInteger)fakeTouchId:(NSInteger)pointId AtPoint:(CGPoint)point withTouchPhase:(UITouchPhase)phase{
    //DLog(@"4. fakeTouchId , phase : %ld ",(long)phase);
    if (pointId==0) {
        //随机一个没有使用的pointId
        pointId = [self getAvailablePointId];
        if (pointId==0) {
            DLog(@"PTFakeTouch ERROR! pointId all used");
            return 0;
        }
    }
    pointId = pointId - 1;
    UITouch *touch = [touchAry objectAtIndex:pointId];
    if (phase == UITouchPhaseBegan) {
        // v1.0.76：自愈——该槽位旧触摸若仍在飞（Stationary，被抢过槽位/泄漏残留），
        // 先给它补发一个 Ended 把 App 里粘住的手指清掉（升级后无需杀 App 自愈），再替换。
        // 正常序列里 Begin 前的旧触摸必然已是 Ended，本分支只对泄漏残留生效。
        UITouch *prev = [touchAry objectAtIndex:pointId];
        if (prev.phase == UITouchPhaseStationary) {
            [prev setPhaseAndUpdateTimestamp:UITouchPhaseEnded];
            UIEvent *healEvent = [self eventWithTouches:touchAry];   // 此刻 touchAry 仍持 prev
            [[UIApplication sharedApplication] sendEvent:healEvent];
        }
        touch = nil;
        touch = [[UITouch alloc] initAtPoint:point inWindow:[UIApplication sharedApplication].keyWindow];
        
        // - Keyboard - (Keyboard FIX: Artem Levkovich, ITRex Group)
        CGRect keyboardFrame;
        // AppDelegate *appDelegate = (AppDelegate *)[[UIApplication sharedApplication] delegate];
        // keyboardFrame = appDelegate.keyboardFrame; (get keyboard frame using UIKeyboardDidShowNotification)
        if([[[UIApplication sharedApplication].windows lastObject] isKindOfClass:NSClassFromString(@"UIRemoteKeyboardWindow")] && (CGRectContainsPoint(CGRectMake(0, [UIApplication sharedApplication].keyWindow.frame.size.height-keyboardFrame.size.height, [UIApplication sharedApplication].keyWindow.frame.size.width, keyboardFrame.size.height), point))) {
            touch = [[UITouch alloc] initAtPoint:point inWindow:[[UIApplication sharedApplication].windows lastObject]];
        }
        
        [touchAry replaceObjectAtIndex:pointId withObject:touch];
        [touch setLocationInWindow:point];
    }else{
        [touch setLocationInWindow:point];
        [touch setPhaseAndUpdateTimestamp:phase];
    }
    
    
    
    UIEvent *event = [self eventWithTouches:touchAry];
    [[UIApplication sharedApplication] sendEvent:event];
    if ((touch.phase==UITouchPhaseBegan)||touch.phase==UITouchPhaseMoved) {
        [touch setPhaseAndUpdateTimestamp:UITouchPhaseStationary];
    }
    return (pointId+1);
}


+ (UIEvent *)eventWithTouches:(NSArray *)touches
{
    // _touchesEvent is a private selector, interface is exposed in UIApplication(KIFAdditionsPrivate)
    UIEvent *event = [[UIApplication sharedApplication] _touchesEvent];
    [event _clearTouches];
    [event kif_setEventWithTouches:touches];
    
    for (UITouch *aTouch in touches) {
        [event _addTouch:aTouch forDelayedDelivery:NO];
    }
    
    return event;
}

+ (NSInteger)getAvailablePointId{
    NSInteger availablePointId=0;
    NSMutableArray *availableIds = [[NSMutableArray alloc]init];
    for (NSInteger i=0; i<touchAry.count-50; i++) {
        UITouch *touch = [touchAry objectAtIndex:i];
        // v1.0.76：只有「已结束(Ended)」的槽位才是空闲的。
        // Stationary 恰恰是在飞触摸每次注入后被置的相位（见 fakeTouchId 尾部 66-67 行）——
        // 旧代码把它也算空闲 → 未命中重放有 1/50 概率抢走正在滑行的方案回放槽位：
        // 原 UITouch 对象被就地替换且永远收不到 Ended → App 里粘手卡死，
        // 之后每次新手势都多叠一根粘住的手指（多指 centroid 降速、点击点不中）。
        if (touch.phase==UITouchPhaseEnded) {
            [availableIds addObject:@(i+1)];
        }
    }
    availablePointId = availableIds.count==0 ? 0 : [[availableIds objectAtIndex:(arc4random() % availableIds.count)] integerValue];
    return availablePointId;
}

+ (BOOL)isPoolTouch:(UITouch *)touch{
    return touch && [touchAry containsObject:touch];
}
@end
