#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

// ==========================================
// 1. INTERFACE DECLARATIONS
// ==========================================

@interface SBIconView : UIView
@property (nonatomic, strong) id icon;
@end

@interface LMTransitionState : NSObject
@property (nonatomic, strong) CALayer *backdrop;
@property (nonatomic, strong) CAShapeLayer *maskShape;
@property (nonatomic, strong) CALayer *iconLayer;
@property (nonatomic, assign) CGRect iconFrame;
@property (nonatomic, assign) BOOL isOpening;
@end

@implementation LMTransitionState
@end

// ==========================================
// 2. BIẾN TOÀN CỤC
// ==========================================

static LMTransitionState *gCurrentState = nil;
static UIWindow *gOverlayWindow = nil;
static BOOL gIsCustomAppLaunching = NO;

#define LMLog(fmt, ...) NSLog(@"[LiquidMorph] " fmt, ##__VA_ARGS__)

// ==========================================
// 3. TOÁN HỌC VẼ ĐƯỜNG CONG TỐI ƯU (LIGHTWEIGHT)
// ==========================================

static CGPathRef LMRoundedQuadPath(CGPoint tl, CGPoint tr, CGPoint br, CGPoint bl,
                                    CGFloat rTL, CGFloat rTR, CGFloat rBR, CGFloat rBL) {
    NSArray *points = @[[NSValue valueWithCGPoint:tl], [NSValue valueWithCGPoint:tr],
                         [NSValue valueWithCGPoint:br], [NSValue valueWithCGPoint:bl]];
    NSArray *radii = @[@(rTL), @(rTR), @(rBR), @(rBL)];
    CGMutablePathRef path = CGPathCreateMutable();
    NSInteger n = points.count;
    
    CGPoint (^getPoint)(NSInteger) = ^CGPoint(NSInteger idx) {
        return [points[(idx + n) % n] CGPointValue];
    };
    
    for (NSInteger i = 0; i < n; i++) {
        CGPoint cur = getPoint(i);
        CGPoint prev = getPoint(i - 1);
        CGPoint next = getPoint(i + 1);
        CGFloat r = [radii[i] floatValue];
        CGFloat distPrev = hypot(cur.x - prev.x, cur.y - prev.y);
        CGFloat distNext = hypot(cur.x - next.x, cur.y - next.y);
        CGFloat rClamped = MIN(r, MIN(distPrev, distNext) * 0.5);
        
        CGFloat toPrevX = (prev.x - cur.x) / (distPrev > 0 ? distPrev : 1);
        CGFloat toPrevY = (prev.y - cur.y) / (distPrev > 0 ? distPrev : 1);
        CGFloat toNextX = (next.x - cur.x) / (distNext > 0 ? distNext : 1);
        CGFloat toNextY = (next.y - cur.y) / (distNext > 0 ? distNext : 1);
        
        CGPoint p1 = CGPointMake(cur.x + toPrevX * rClamped, cur.y + toPrevY * rClamped);
        CGPoint p2 = CGPointMake(cur.x + toNextX * rClamped, cur.y + toNextY * rClamped);
        
        if (i == 0) { 
            CGPathMoveToPoint(path, NULL, p1.x, p1.y); 
        } else { 
            CGPathAddLineToPoint(path, NULL, p1.x, p1.y); 
        }
        CGPathAddQuadCurveToPoint(path, NULL, cur.x, cur.y, p2.x, p2.y);
    }
    CGPathCloseSubpath(path);
    return path;
}

static CGFloat LMEdgeProgress(CGFloat t, CGFloat closeness, CGFloat maxDelay) {
    CGFloat delay = closeness * maxDelay;
    CGFloat span = 1.0 - delay;
    if (span <= 0) span = 0.001;
    CGFloat edgeT = (t - delay) / span;
    if (edgeT < 0) edgeT = 0;
    if (edgeT > 1) edgeT = 1;
    return edgeT;
}

static CGFloat LMHumpRadius(CGFloat t) {
    CGFloat iconRadius = 14.0;
    CGFloat peakRadius = 85.0;
    CGFloat endRadius = 0.0;
    if (t < 0.5) {
        CGFloat local = t / 0.5;
        return iconRadius + (peakRadius - iconRadius) * local;
    } else {
        CGFloat local = (t - 0.5) / 0.5;
        return peakRadius + (endRadius - peakRadius) * local;
    }
}

static UIImage *LMSafeExtractIconImage(UIView *iconView) {
    if (!iconView) return nil;
    if (iconView.layer.contents) {
        return [UIImage imageWithCGImage:(__bridge CGImageRef)iconView.layer.contents];
    }
    return nil;
}

static NSArray *LMBuildKeyframePaths(CGRect iconFrame, CGRect screen, BOOL opening) {
    CGFloat iconCenterXNorm = (iconFrame.origin.x + iconFrame.size.width / 2.0) / screen.size.width;
    CGFloat iconCenterYNorm = (iconFrame.origin.y + iconFrame.size.height / 2.0) / screen.size.height;

    CGFloat closeBottom = iconCenterYNorm;
    CGFloat closeTop = 1.0 - iconCenterYNorm;
    CGFloat closeRight = iconCenterXNorm;
    CGFloat closeLeft = 1.0 - iconCenterXNorm;

    // Giảm xuống 14 bước để tối ưu CPU/GPU mượt mà
    NSInteger steps = 14;
    NSMutableArray *paths = [NSMutableArray arrayWithCapacity:steps + 1];
    CGFloat maxDelay = 0.25;
    CGFloat iconRadius = 14.0;
    CGFloat growStart = 0.08;

    CGFloat iconLeft = iconFrame.origin.x;
    CGFloat iconRight = iconFrame.origin.x + iconFrame.size.width;
    CGFloat iconTop = iconFrame.origin.y;
    CGFloat iconBottom = iconFrame.origin.y + iconFrame.size.height;
    CGFloat screenLeft = screen.origin.x;
    CGFloat screenRight = screen.origin.x + screen.size.width;
    CGFloat screenTop = screen.origin.y;
    CGFloat screenBottom = screen.origin.y + screen.size.height;

    for (NSInteger i = 0; i <= steps; i++) {
        CGFloat tRaw = (CGFloat)i / (CGFloat)steps;
        CGFloat t = opening ? tRaw : (1.0 - tRaw);
        CGPathRef p;

        if (t < growStart) {
            p = LMRoundedQuadPath(
                CGPointMake(iconLeft, iconTop), CGPointMake(iconRight, iconTop),
                CGPointMake(iconRight, iconBottom), CGPointMake(iconLeft, iconBottom),
                iconRadius, iconRadius, iconRadius, iconRadius);
        } else {
            CGFloat t2 = (t - growStart) / (1.0 - growStart);

            CGFloat topP = LMEdgeProgress(t2, closeTop, maxDelay);
            CGFloat bottomP = LMEdgeProgress(t2, closeBottom, maxDelay);
            CGFloat leftP = LMEdgeProgress(t2, closeLeft, maxDelay);
            CGFloat rightP = LMEdgeProgress(t2, closeRight, maxDelay);

            CGFloat topY = iconTop + (screenTop - iconTop) * topP;
            CGFloat bottomY = iconBottom + (screenBottom - iconBottom) * bottomP;
            CGFloat topLeftX = iconLeft + (screenLeft - iconLeft) * ((topP + leftP) * 0.5);
            CGFloat topRightX = iconRight + (screenRight - iconRight) * ((topP + rightP) * 0.5);
            CGFloat bottomLeftX = iconLeft + (screenLeft - iconLeft) * ((bottomP + leftP) * 0.5);
            CGFloat bottomRightX = iconRight + (screenRight - iconRight) * ((bottomP + rightP) * 0.5);

            CGPoint tl = CGPointMake(topLeftX, topY);
            CGPoint tr = CGPointMake(topRightX, topY);
            CGPoint br = CGPointMake(bottomRightX, bottomY);
            CGPoint bl = CGPointMake(bottomLeftX, bottomY);

            CGFloat humpBase = LMHumpRadius(t2);

            CGFloat rTL = humpBase * (1.0 - MIN(topP, leftP));
            CGFloat rTR = humpBase * (1.0 - MIN(topP, rightP));
            CGFloat rBR = humpBase * (1.0 - MIN(bottomP, rightP));
            CGFloat rBL = humpBase * (1.0 - MIN(bottomP, leftP));

            p = LMRoundedQuadPath(tl, tr, br, bl, rTL, rTR, rBR, rBL);
        }

        [paths addObject:(__bridge_transfer id)p];
    }
    return paths;
}

// ==========================================
// 4. OVERLAY ANIMATION ENGINE (MƯỢT MÀ)
// ==========================================

static void LMForceClearOverlay(void) {
    if (gOverlayWindow) {
        gOverlayWindow.hidden = YES;
        NSArray *sublayers = [gOverlayWindow.layer.sublayers copy];
        for (CALayer *l in sublayers) {
            [l removeFromSuperlayer];
        }
    }
    gCurrentState = nil;
    gIsCustomAppLaunching = NO;
}

static void LMEnsureWindow(void) {
    if (!gOverlayWindow) {
        gOverlayWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        gOverlayWindow.windowLevel = UIWindowLevelStatusBar + 1000;
        gOverlayWindow.userInteractionEnabled = NO;
        gOverlayWindow.backgroundColor = [UIColor clearColor];
    }
    
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                gOverlayWindow.windowScene = (UIWindowScene *)scene;
                break;
            }
        }
    }
    gOverlayWindow.hidden = NO;
}

static void LMPlayTransition(CGRect iconFrame, UIImage *iconImage, BOOL opening) {
    LMForceClearOverlay();
    LMEnsureWindow();

    gIsCustomAppLaunching = YES;
    CGRect screen = gOverlayWindow.bounds;
    
    // Tăng thời gian lên 0.68 giây cho cảm giác chuyển cảnh chậm rãi, mượt mà như iOS 26
    CGFloat duration = 0.68;

    CAShapeLayer *maskShape = [CAShapeLayer layer];
    maskShape.frame = screen;

    CALayer *iconLayer = [CALayer layer];
    iconLayer.frame = screen;
    iconLayer.contentsGravity = kCAGravityResizeAspectFill;
    if (iconImage) {
        iconLayer.contents = (__bridge id)iconImage.CGImage;
    } else {
        iconLayer.backgroundColor = [UIColor colorWithRed:0.1 green:0.6 blue:1.0 alpha:1.0].CGColor;
    }
    iconLayer.mask = maskShape;
    [gOverlayWindow.layer addSublayer:iconLayer];

    NSArray *paths = LMBuildKeyframePaths(iconFrame, screen, opening);

    CAKeyframeAnimation *pathAnim = [CAKeyframeAnimation animationWithKeyPath:@"path"];
    pathAnim.values = paths;
    pathAnim.duration = duration;
    // Sử dụng đường cong lực đàn hồi cho hiệu ứng phồng mượt
    pathAnim.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.22 :1.0 :0.36 :1.0];
    pathAnim.fillMode = kCAFillModeForwards;
    pathAnim.removedOnCompletion = NO;

    maskShape.path = (__bridge CGPathRef)paths.lastObject;
    [maskShape addAnimation:pathAnim forKey:@"morph"];

    LMTransitionState *state = [LMTransitionState new];
    state.maskShape = maskShape;
    state.iconLayer = iconLayer;
    state.iconFrame = iconFrame;
    state.isOpening = opening;
    gCurrentState = state;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gCurrentState == state) {
            LMForceClearOverlay();
        }
    });
}

// ==========================================
// 5. HOOKS: ẨN ANIMATION MỞ APP GỐC VÀ DỰ DÒNG AN TOÀN
// ==========================================

%hook SBUIAnimationController

- (void)_willBegin {
    %orig;
    if (gIsCustomAppLaunching) {
        @try {
            Ivar containerIvar = class_getInstanceVariable([self class], "_containerView");
            if (containerIvar) {
                UIView *containerView = object_getIvar(self, containerIvar);
                if ([containerView isKindOfClass:[UIView class]]) {
                    containerView.alpha = 0.0;
                }
            }
        } @catch (NSException *e) {}
    }
}

- (void)_cleanupAnimation {
    %orig;
    @try {
        Ivar containerIvar = class_getInstanceVariable([self class], "_containerView");
        if (containerIvar) {
            UIView *containerView = object_getIvar(self, containerIvar);
            if ([containerView isKindOfClass:[UIView class]]) {
                containerView.alpha = 1.0;
            }
        }
    } @catch (NSException *e) {}
}

%end

%hook SBIconView

- (void)_handleTap {
    @try {
        id icon = nil;
        if ([self respondsToSelector:@selector(icon)]) {
            icon = [self icon];
        }
        
        if (icon) {
            NSString *className = NSStringFromClass([icon class]);
            BOOL isFolderLike = [className.lowercaseString containsString:@"folder"] ||
                                 [className.lowercaseString containsString:@"library"] ||
                                 [className.lowercaseString containsString:@"cluster"];

            if (isFolderLike) {
                %orig;
                return;
            }
        }

        if (self.window) {
            CGRect frameInWindow = [self.window convertRect:self.bounds fromView:self];
            UIImage *iconImage = LMSafeExtractIconImage(self);
            LMPlayTransition(frameInWindow, iconImage, YES);
        }
    } @catch (NSException *e) {
        LMLog(@"Exception in _handleTap: %@", e.reason);
    }
    %orig;
}

%end

// ==========================================
// 6. INITIALIZER
// ==========================================

%ctor {
    @autoreleasepool {
        LMLog(@"LiquidMorph loaded: Smooth animation mode enabled.");
    }
}
