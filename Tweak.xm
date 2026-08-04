#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// ==========================================
// 1. DỮ LIỆU CẤU TRÚC VÀ TRẠNG THÁI TOÀN CỤC
// ==========================================

@interface LMTransitionState : NSObject
@property (nonatomic, strong) CAShapeLayer *maskShape;
@property (nonatomic, strong) CALayer *iconLayer;
@property (nonatomic, assign) CGRect iconFrame;
@property (nonatomic, assign) BOOL isOpening;
@end

@implementation LMTransitionState
@end

static LMTransitionState *gCurrentState = nil;
static UIWindow *gOverlayWindow = nil;
static BOOL gIsCustomAppLaunching = NO;

// ==========================================
// 2. TỐI ƯU VẼ DƯỜNG CONG (CGPATH ENGINE)
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
    return (edgeT < 0) ? 0 : ((edgeT > 1) ? 1 : edgeT);
}

static CGFloat LMHumpRadius(CGFloat t) {
    if (t < 0.45) {
        return 13.0 + (90.0 - 13.0) * (t / 0.45);
    } else {
        CGFloat local = (t - 0.45) / 0.55;
        return 90.0 + (0.0 - 90.0) * (local > 1.0 ? 1.0 : local);
    }
}

static NSArray *LMBuildKeyframePaths(CGRect iconFrame, CGRect screen, BOOL opening) {
    CGFloat iconCenterXNorm = (iconFrame.origin.x + iconFrame.size.width / 2.0) / screen.size.width;
    CGFloat iconCenterYNorm = (iconFrame.origin.y + iconFrame.size.height / 2.0) / screen.size.height;

    CGFloat closeBottom = iconCenterYNorm;
    CGFloat closeTop = 1.0 - iconCenterYNorm;
    CGFloat closeRight = iconCenterXNorm;
    CGFloat closeLeft = 1.0 - iconCenterXNorm;

    NSInteger steps = 16;
    NSMutableArray *paths = [NSMutableArray arrayWithCapacity:steps + 1];
    CGFloat maxDelay = 0.30;
    CGFloat iconRadius = 13.0;
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
        
        [paths addObject:(__bridge id)p];
        CGPathRelease(p);
    }
    return paths;
}

// ==========================================
// 3. QUẢN LÝ QUÁ TRÌNH CHUYỂN CẢNH
// ==========================================

static void LMForceClearOverlay(void) {
    if (gOverlayWindow) {
        gOverlayWindow.hidden = YES;
        for (CALayer *l in [gOverlayWindow.layer.sublayers copy]) {
            [l removeFromSuperlayer];
        }
    }
    gCurrentState = nil;
    gIsCustomAppLaunching = NO;
}

static void LMEnsureWindow(void) {
    if (!gOverlayWindow) {
        gOverlayWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        gOverlayWindow.windowLevel = UIWindowLevelStatusBar + 5;
        gOverlayWindow.userInteractionEnabled = NO;
        gOverlayWindow.backgroundColor = [UIColor clearColor];
    }
    
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
            gOverlayWindow.windowScene = (UIWindowScene *)scene;
            break;
        }
    }
    gOverlayWindow.hidden = NO;
}

static void LMPlayTransition(CGRect iconFrame, UIImage *iconImage, BOOL opening) {
    LMForceClearOverlay();
    LMEnsureWindow();

    gIsCustomAppLaunching = YES;
    CGRect screen = gOverlayWindow.bounds;
    CGFloat duration = 0.28; 

    CAShapeLayer *maskShape = [CAShapeLayer layer];
    maskShape.frame = screen;

    CALayer *iconLayer = [CALayer layer];
    iconLayer.frame = screen;
    iconLayer.contentsGravity = kCAGravityResizeAspectFill;
    
    if (iconImage) {
        iconLayer.contents = (__bridge id)iconImage.CGImage;
    } else {
        iconLayer.backgroundColor = [UIColor colorWithRed:0.08 green:0.75 blue:0.95 alpha:1.0].CGColor;
    }
    
    iconLayer.mask = maskShape;
    [gOverlayWindow.layer addSublayer:iconLayer];

    NSArray *paths = LMBuildKeyframePaths(iconFrame, screen, opening);
    if (paths.count == 0) {
        LMForceClearOverlay();
        return;
    }

    CAKeyframeAnimation *pathAnim = [CAKeyframeAnimation animationWithKeyPath:@"path"];
    pathAnim.values = paths;
    pathAnim.duration = duration;
    pathAnim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
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
// 4. HOOKS: ẨN ANIMATION MỞ APP GỐC
// ==========================================

%hook SBUIAnimationController
- (void)_willBegin {
    %orig;
    if (gIsCustomAppLaunching) {
        UIView *containerView = [self valueForKey:@"_containerView"];
        if (containerView) {
            containerView.alpha = 0.0;
        }
    }
}
- (void)_cleanupAnimation {
    %orig;
    UIView *containerView = [self valueForKey:@"_containerView"];
    if (containerView) {
        containerView.alpha = 1.0;
    }
}
%end

%hook SBIconView
- (void)_handleTap {
    @try {
        id icon = [self valueForKey:@"icon"];
        NSString *className = NSStringFromClass([icon class]);

        BOOL isFolderLike = [className.lowercaseString containsString:@"folder"] ||
                             [className.lowercaseString containsString:@"library"] ||
                             [className.lowercaseString containsString:@"cluster"];

        if (!isFolderLike && self.window != nil) {
            CGRect frameInWindow = [self.window convertRect:self.bounds fromView:self];
            
            UIImage *iconImage = nil;
            if (self.layer.contents) {
                iconImage = [UIImage imageWithCGImage:(__bridge CGImageRef)self.layer.contents];
            }
            
            LMPlayTransition(frameInWindow, iconImage, YES);
        }
    } @catch (NSException *e) {}
    %orig;
}
%end

// ==========================================
// 5. HOOKS: ẨN THÔNG BÁO GỐC & TẠO HIỆU ỨNG iOS 26
// ==========================================

%hook NCNotificationShortLookView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        UIView *backgroundMaterialView = [self valueForKey:@"_backgroundMaterialView"];
        if (backgroundMaterialView) {
            backgroundMaterialView.alpha = 0.0;
        }

        self.backgroundColor = [UIColor colorWithRed:0.07 green:0.09 blue:0.12 alpha:0.78];
        self.layer.cornerRadius = 24.0;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithRed:0.35 green:0.85 blue:1.0 alpha:0.35].CGColor;
        
        self.layer.shadowColor = [UIColor colorWithRed:0.20 green:0.80 blue:1.0 alpha:0.45].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 10);
        self.layer.shadowOpacity = 1.0;
        self.layer.shadowRadius = 18.0;

        self.transform = CGAffineTransformMakeScale(0.80, 0.80);
        self.alpha = 0.0;
        
        [UIView animateWithDuration:0.42 
                              delay:0.0 
             usingSpringWithDamping:0.68 
              initialSpringVelocity:0.7 
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseInOut 
                         animations:^{
            self.transform = CGAffineTransformIdentity;
            self.alpha = 1.0;
        } completion:nil];
    }
}

%end

%ctor {
    @autoreleasepool {
        LMForceClearOverlay();
    }
}
