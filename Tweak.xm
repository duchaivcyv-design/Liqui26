#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

static NSString *const kLogPath = @"/var/mobile/Documents/LiquidMorph.log";

static void LMLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [formatter stringFromDate:[NSDate date]], message];
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:kLogPath]) [fm createFileAtPath:kLogPath contents:nil attributes:nil];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
    } @catch (NSException *e) { NSLog(@"[LiquidMorph] Log write failed: %@", e.reason); }
    NSLog(@"[LiquidMorph] %@", message);
}

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
    CGFloat peakRadius = 120.0;
    CGFloat endRadius = 20.0;
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
static CGRect gLastOpenedIconFrame = CGRectZero;
static BOOL gIsCustomTransitionActive = NO;

static BOOL LMIsInAppSwitcher(void) {
    @try {
        Class appSwitcherControllerClass = objc_getClass("SBMainSwitcherViewController");
        if (!appSwitcherControllerClass) {
            appSwitcherControllerClass = objc_getClass("SBAppSwitcherController");
        }
        if (appSwitcherControllerClass) {
            SEL selShared = NSSelectorFromString(@"sharedInstance");
            if ([appSwitcherControllerClass respondsToSelector:selShared]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id switcher = [appSwitcherControllerClass performSelector:selShared];
#pragma clang diagnostic pop
                if (switcher) {
                    SEL selActive = NSSelectorFromString(@"isSwitcherVisible");
                    if ([switcher respondsToSelector:selActive]) {
                        NSMethodSignature *sig = [switcher methodSignatureForSelector:selActive];
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        [inv setTarget:switcher];
                        [inv setSelector:selActive];
                        [inv invoke];
                        BOOL visible = NO;
                        [inv getReturnValue:&visible];
                        if (visible) return YES;
                    }
                }
            }
        }
    } @catch (NSException *e) {}
    return NO;
}

static NSArray *LMBuildKeyframePaths(CGRect iconFrame, CGRect screen, BOOL opening) {
    CGFloat iconCenterXNorm = (iconFrame.origin.x + iconFrame.size.width / 2.0) / screen.size.width;
    CGFloat iconCenterYNorm = (iconFrame.origin.y + iconFrame.size.height / 2.0) / screen.size.height;

    CGFloat closeBottom = iconCenterYNorm;
    CGFloat closeTop = 1.0 - iconCenterYNorm;
    CGFloat closeRight = iconCenterXNorm;
    CGFloat closeLeft = 1.0 - iconCenterXNorm;

    NSInteger steps = 32;
    NSMutableArray *paths = [NSMutableArray array];
    CGFloat maxDelay = 0.4;
    CGFloat endRadius = 20.0;
    CGFloat iconRadius = 13.0;
    CGFloat growStart = 0.15;

    CGFloat bounceDirection = (iconCenterYNorm > 0.5) ? -1.0 : 1.0;
    CGFloat bounceAmount = 42.0;

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
    }
    gCurrentState = nil;
    gIsCustomTransitionActive = NO;
}

static void LMEnsureWindow(void) {
    if (gOverlayWindow) return;
    gOverlayWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    gOverlayWindow.windowLevel = UIWindowLevelStatusBar + 3000;
    gOverlayWindow.userInteractionEnabled = NO;
    gOverlayWindow.backgroundColor = [UIColor clearColor];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                gOverlayWindow.windowScene = (UIWindowScene *)scene;
                break;
            }
        }
    }
    gOverlayWindow.hidden = NO;
}

static void LMPlayTransition(CGRect iconFrame, UIImage *iconImage, BOOL opening) {
    if (gIsCustomTransitionActive) return;

    LMForceClearOverlay();
    LMEnsureWindow();

    gIsCustomTransitionActive = YES;
    if (opening) {
        gLastOpenedIconFrame = iconFrame;
    }

    CGRect screen = gOverlayWindow.bounds;
    CGFloat duration = 0.65;

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
        iconLayer.backgroundColor = [UIColor colorWithWhite:0.85 alpha:1.0].CGColor;
    }
    iconLayer.mask = maskShape;
    [gOverlayWindow.layer addSublayer:iconLayer];

    CAShapeLayer *maskShape2 = [CAShapeLayer layer];
    maskShape2.frame = screen;
    CALayer *colorLayer = [CALayer layer];
    colorLayer.frame = screen;
    colorLayer.backgroundColor = LMSystemBackgroundColor().CGColor;
    colorLayer.opacity = 0.0;
    colorLayer.mask = maskShape2;
    [gOverlayWindow.layer addSublayer:colorLayer];

    NSArray *paths = LMBuildKeyframePaths(iconFrame, screen, opening);

    CAKeyframeAnimation *pathAnim = [CAKeyframeAnimation animationWithKeyPath:@"path"];
    pathAnim.values = paths;
    pathAnim.duration = duration;
    pathAnim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    pathAnim.fillMode = kCAFillModeForwards;
    pathAnim.removedOnCompletion = NO;

    maskShape.path = (__bridge CGPathRef)paths.lastObject;
    [maskShape addAnimation:pathAnim forKey:@"morph"];

    maskShape2.path = (__bridge CGPathRef)paths.lastObject;
    [maskShape2 addAnimation:pathAnim forKey:@"morph"];

    CAKeyframeAnimation *fadeAnim = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    fadeAnim.values = @[@0.0, @0.0, @1.0, @1.0];
    fadeAnim.keyTimes = @[@0.0, @0.55, @0.66, @1.0];
    fadeAnim.duration = duration;
    fadeAnim.fillMode = kCAFillModeForwards;
    fadeAnim.removedOnCompletion = NO;

    colorLayer.opacity = 1.0;
    [colorLayer addAnimation:fadeAnim forKey:@"fade"];

    LMTransitionState *state = [LMTransitionState new];
    state.backdrop = backdrop;
    state.maskShape = maskShape;
    state.iconLayer = iconLayer;
    state.colorLayer = colorLayer;
    state.iconFrame = iconFrame;
    state.isOpening = opening;
    gCurrentState = state;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((duration + 0.05) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gCurrentState == state) {
            [backdrop removeFromSuperlayer];
            [iconLayer removeFromSuperlayer];
            [colorLayer removeFromSuperlayer];
            gCurrentState = nil;
            gIsCustomTransitionActive = NO;
        }
    });
}

@interface SBIconView : UIView
- (id)icon;
@end

%hook SBIconView

- (void)_handleTap {
    @try {
        if (gIsCustomTransitionActive || LMIsInAppSwitcher()) {
            %orig;
            return;
        }

        id icon = [self valueForKey:@"icon"];
        NSString *className = NSStringFromClass([icon class]);

        BOOL isFolderLike = [className.lowercaseString containsString:@"folder"] ||
                             [className.lowercaseString containsString:@"library"] ||
                             [className.lowercaseString containsString:@"cluster"];

        if (isFolderLike) {
            %orig;
            return;
        }

        if ([icon respondsToSelector:@selector(application)]) {
            id app = [icon performSelector:@selector(application)];
            if (app && [app respondsToSelector:@selector(bundleIdentifier)]) {
                NSString *bundleID = [app performSelector:@selector(bundleIdentifier)];
                if (!bundleID || bundleID.length == 0) {
                    %orig;
                    return;
                }
            }
        }

        CGRect frameInWindow = [self.window convertRect:self.bounds fromView:self];
        if (CGRectIsEmpty(frameInWindow) || frameInWindow.size.width < 10) {
            %orig;
            return;
        }

        UIImage *iconImage = LMRenderIconImage(self);
        LMPlayTransition(frameInWindow, iconImage, YES);
    } @catch (NSException *e) {}
    %orig;
}

%end

@interface SBWorkspaceApplicationSceneTransitionContext : NSObject
@end

%hook SBWorkspaceApplicationSceneTransitionContext

- (void)setAnimationDisabled:(BOOL)disabled {
    if (LMIsInAppSwitcher()) {
        %orig(disabled);
        return;
    }

    if (!gIsCustomTransitionActive && gLastOpenedIconFrame.size.width > 0 && gCurrentState == nil) {
        LMPlayTransition(gLastOpenedIconFrame, nil, NO);
    }
    %orig(disabled);
}

%end

@interface SBIconController : NSObject
- (void)handleHomeButtonTap;
@end

%hook SBIconController

- (void)handleHomeButtonTap {
    @try {
        if (gIsCustomTransitionActive || LMIsInAppSwitcher()) {
            %orig;
            return;
        }

        if (gCurrentState && gCurrentState.isOpening) {
            CGRect iconFrame = gCurrentState.iconFrame;
            LMPlayTransition(iconFrame, nil, NO);
        } else if (gLastOpenedIconFrame.size.width > 0) {
            LMPlayTransition(gLastOpenedIconFrame, nil, NO);
        }
    } @catch (NSException *e) {}
    %orig;
}

%end

%ctor {
    LMLog(@"=== LiquidMorph v10.2 Final Clean Loaded ===");
}
