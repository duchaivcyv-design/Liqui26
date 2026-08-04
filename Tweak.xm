#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

// 1. DUONG DAN LOG AN TOAN CHO ROOTLESS & iOS 15+
static NSString *getSafeLogPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"LiquidMorph.log"];
}

static void LMLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [formatter stringFromDate:[NSDate date]], message];
    @try {
        NSString *path = getSafeLogPath();
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
    } @catch (NSException *e) { NSLog(@"[LiquidMorph] Log error: %@", e.reason); }
    NSLog(@"[LiquidMorph] %@", message);
}

// 2. CAC HAM TINH TOAN MORPHING & MATH
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
        if (i == 0) { CGPathMoveToPoint(path, NULL, p1.x, p1.y); }
        else { CGPathAddLineToPoint(path, NULL, p1.x, p1.y); }
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
    CGFloat iconRadius = 13.0;
    CGFloat peakRadius = 100.0;
    CGFloat endRadius = 0.0; // Phong kín góc màn hình mở app
    if (t < 0.45) {
        CGFloat local = t / 0.45;
        return iconRadius + (peakRadius - iconRadius) * local;
    } else {
        CGFloat local = (t - 0.45) / 0.55;
        if (local > 1) local = 1;
        return peakRadius + (endRadius - peakRadius) * local;
    }
}

static UIColor *LMSystemBackgroundColor(void) {
    if (@available(iOS 13.0, *)) {
        return [UIColor systemBackgroundColor];
    }
    return [UIColor whiteColor];
}

static UIImage *LMRenderIconImage(UIView *iconView) {
    if (!iconView) return nil;
    CGSize size = iconView.bounds.size;
    if (size.width <= 0 || size.height <= 0) return nil;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [iconView.layer renderInContext:ctx.CGContext];
    }];
}

@interface LMTransitionState : NSObject
@property (nonatomic, strong) CALayer *backdrop;
@property (nonatomic, strong) CAShapeLayer *maskShape;
@property (nonatomic, strong) CALayer *iconLayer;
@property (nonatomic, strong) CALayer *colorLayer;
@property (nonatomic, assign) CGRect iconFrame;
@property (nonatomic, assign) BOOL isOpening;
@end
@implementation LMTransitionState
@end

static LMTransitionState *gCurrentState = nil;
static UIWindow *gOverlayWindow = nil;

static NSArray *LMBuildKeyframePaths(CGRect iconFrame, CGRect screen, BOOL opening) {
    CGFloat iconCenterXNorm = (iconFrame.origin.x + iconFrame.size.width / 2.0) / screen.size.width;
    CGFloat iconCenterYNorm = (iconFrame.origin.y + iconFrame.size.height / 2.0) / screen.size.height;

    CGFloat closeBottom = iconCenterYNorm;
    CGFloat closeTop = 1.0 - iconCenterYNorm;
    CGFloat closeRight = iconCenterXNorm;
    CGFloat closeLeft = 1.0 - iconCenterXNorm;

    NSInteger steps = 24;
    NSMutableArray *paths = [NSMutableArray array];
    CGFloat maxDelay = 0.35;
    CGFloat endRadius = 0.0;
    CGFloat iconRadius = 13.0;
    CGFloat growStart = 0.08;

    CGFloat bounceDirection = (iconCenterYNorm > 0.5) ? -1.0 : 1.0;
    CGFloat bounceAmount = 30.0;

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

            CGFloat bounceEnvelope = sinf(MIN(t2, 1.0) * M_PI) * bounceAmount * bounceDirection;

            CGFloat topY = iconTop + (screenTop - iconTop) * topP + bounceEnvelope * (1.0 - topP);
            CGFloat bottomY = iconBottom + (screenBottom - iconBottom) * bottomP + bounceEnvelope * (1.0 - bottomP);

            CGFloat topLeftX = iconLeft + (screenLeft - iconLeft) * ((topP + leftP) * 0.5);
            CGFloat topRightX = iconRight + (screenRight - iconRight) * ((topP + rightP) * 0.5);
            CGFloat bottomLeftX = iconLeft + (screenLeft - iconLeft) * ((bottomP + leftP) * 0.5);
            CGFloat bottomRightX = iconRight + (screenRight - iconRight) * ((bottomP + rightP) * 0.5);

            CGPoint tl = CGPointMake(topLeftX, topY);
            CGPoint tr = CGPointMake(topRightX, topY);
            CGPoint br = CGPointMake(bottomRightX, bottomY);
            CGPoint bl = CGPointMake(bottomLeftX, bottomY);

            CGFloat humpBase = LMHumpRadius(t2);

            CGFloat rTL = humpBase * (1.0 - MIN(topP, leftP)) + endRadius * MIN(topP, leftP);
            CGFloat rTR = humpBase * (1.0 - MIN(topP, rightP)) + endRadius * MIN(topP, rightP);
            CGFloat rBR = humpBase * (1.0 - MIN(bottomP, rightP)) + endRadius * MIN(bottomP, rightP);
            CGFloat rBL = humpBase * (1.0 - MIN(bottomP, leftP)) + endRadius * MIN(bottomP, leftP);

            p = LMRoundedQuadPath(tl, tr, br, bl, rTL, rTR, rBR, rBL);
        }
        [paths addObject:(__bridge_transfer id)p];
    }
    return paths;
}

static void LMForceClearOverlay(void) {
    if (gOverlayWindow) {
        NSArray *sublayers = [gOverlayWindow.layer.sublayers copy];
        for (CALayer *l in sublayers) {
            [l removeFromSuperlayer];
        }
        gOverlayWindow.hidden = YES;
    }
    gCurrentState = nil;
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
            if ([scene isKindOfClass:[UIWindowScene class]] && ((UIWindowScene *)scene).activationState == UISceneActivationStateForegroundActive) {
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

    CGRect screen = gOverlayWindow.bounds;
    // Fast duration (0.32s) de dong bo mượt mà voi App ra giao dien full
    CGFloat duration = 0.32; 

    CALayer *backdrop = [CALayer layer];
    backdrop.frame = screen;
    backdrop.backgroundColor = LMSystemBackgroundColor().CGColor;
    [gOverlayWindow.layer addSublayer:backdrop];

    CAShapeLayer *maskShape = [CAShapeLayer layer];
    maskShape.frame = screen;

    CALayer *iconLayer = [CALayer layer];
    iconLayer.frame = screen;
    iconLayer.contentsGravity = kCAGravityResizeAspectFill;
    if (iconImage) {
        iconLayer.contents = (__bridge id)iconImage.CGImage;
    } else {
        iconLayer.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0].CGColor;
    }
    iconLayer.mask = maskShape;
    [gOverlayWindow.layer addSublayer:iconLayer];

    NSArray *paths = LMBuildKeyframePaths(iconFrame, screen, opening);

    CAKeyframeAnimation *pathAnim = [CAKeyframeAnimation animationWithKeyPath:@"path"];
    pathAnim.values = paths;
    pathAnim.duration = duration;
    pathAnim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    pathAnim.fillMode = kCAFillModeForwards;
    pathAnim.removedOnCompletion = NO;

    maskShape.path = (__bridge CGPathRef)paths.lastObject;
    [maskShape addAnimation:pathAnim forKey:@"morph"];

    LMTransitionState *state = [LMTransitionState new];
    state.backdrop = backdrop;
    state.maskShape = maskShape;
    state.iconLayer = iconLayer;
    state.iconFrame = iconFrame;
    state.isOpening = opening;
    gCurrentState = state;

    // Tu dong don dẹp overlay ngay khi het thoi gian
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gCurrentState == state) {
            LMForceClearOverlay();
        }
    });
}

// 3. AN HIEU UNG GOC SPRINGBOARD (PREVENT CONFLICT & DUPLICATE ANIMATION)
%hook SBUIAnimationController
- (void)_willBegin {
    %orig;
    // An hieu ung goc mo/dong app khi LiquidMorph dang chay
    if (gCurrentState) {
        [self setValue:@(0.01) forKey:@"animationDuration"];
    }
}
%end

// 4. HOOK ICON TAP OPEN / CLOSE APP
@interface SBIconView : UIView
- (id)icon;
@end

%hook SBIconView

- (void)_handleTap {
    @try {
        id icon = [self valueForKey:@"icon"];
        NSString *className = NSStringFromClass([icon class]);

        BOOL isFolderLike = [className.lowercaseString containsString:@"folder"] ||
                             [className.lowercaseString containsString:@"library"] ||
                             [className.lowercaseString containsString:@"cluster"];

        if (isFolderLike) {
            %orig;
            return;
        }

        CGRect frameInWindow = [self.window convertRect:self.bounds fromView:self];
        UIImage *iconImage = LMRenderIconImage(self);
        LMPlayTransition(frameInWindow, iconImage, YES);
    } @catch (NSException *e) {
        LMLog(@"Exception in _handleTap: %@", e.reason);
    }
    %orig;
}

%end

@interface SBIconController : NSObject
- (void)handleHomeButtonTap;
@end

%hook SBIconController

- (void)handleHomeButtonTap {
    @try {
        if (gCurrentState && gCurrentState.isOpening) {
            CGRect iconFrame = gCurrentState.iconFrame;
            LMPlayTransition(iconFrame, nil, NO);
        }
    } @catch (NSException *e) {
        LMLog(@"Exception in handleHomeButtonTap: %@", e.reason);
    }
    %orig;
}

%end

// 5. THEAM HIEU UNG ANIMATION CHUYEN DONG CHO THONG BAO (NOTIFICATION ALERTS)
%hook NCNotificationShortLookView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        self.transform = CGAffineTransformMakeScale(0.75, 0.75);
        self.alpha = 0.0;
        
        [UIView animateWithDuration:0.45 
                              delay:0.0 
             usingSpringWithDamping:0.65 
              initialSpringVelocity:0.8 
                            options:UIViewAnimationOptionCurveEaseInOut 
                         animations:^{
            self.transform = CGAffineTransformIdentity;
            self.alpha = 1.0;
        } completion:nil];
    }
}

%end

// 6. INITIALIZER
%ctor {
    LMLog(@"=== LiquidMorph Ultra Loaded Safe Mode ===");
}
