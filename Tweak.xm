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
    } @catch (NSException *e) {}
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
    CGFloat peakRadius = 45.0;
    CGFloat endRadius = 0.0;
    if (t < 0.5) {
        CGFloat local = t / 0.5;
        return iconRadius + (peakRadius - iconRadius) * local;
    } else {
        CGFloat local = (t - 0.5) / 0.5;
        if (local > 1) local = 1;
        return peakRadius + (endRadius - peakRadius) * local;
    }
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

static UIWindow *gOverlayWindow = nil;
static CGRect gLastOpenedIconFrame = CGRectZero;
static UIImage *gLastOpenedIconImage = nil;
static BOOL gIsTransitionRunning = NO;

static void LMForceClearOverlay(void) {
    if (gOverlayWindow) {
        NSArray *sublayers = [gOverlayWindow.layer.sublayers copy];
        for (CALayer *l in sublayers) {
            [l removeFromSuperlayer];
        }
    }
    gIsTransitionRunning = NO;
}

static void LMEnsureWindow(void) {
    if (gOverlayWindow) return;
    gOverlayWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    gOverlayWindow.windowLevel = UIWindowLevelStatusBar + 99999;
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

static NSArray *LMBuildKeyframePaths(CGRect iconFrame, CGRect screen, BOOL opening) {
    CGFloat iconCenterXNorm = (iconFrame.origin.x + iconFrame.size.width / 2.0) / screen.size.width;
    CGFloat iconCenterYNorm = (iconFrame.origin.y + iconFrame.size.height / 2.0) / screen.size.height;

    CGFloat closeBottom = iconCenterYNorm;
    CGFloat closeTop = 1.0 - iconCenterYNorm;
    CGFloat closeRight = iconCenterXNorm;
    CGFloat closeLeft = 1.0 - iconCenterXNorm;

    NSInteger steps = 40;
    NSMutableArray *paths = [NSMutableArray array];
    CGFloat maxDelay = 0.15;
    CGFloat endRadius = 0.0;
    CGFloat iconRadius = 13.0;
    CGFloat growStart = 0.0;

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

static void LMRunTransition(CGRect iconFrame, UIImage *iconImage, BOOL opening, void(^completion)(void)) {
    LMForceClearOverlay();
    LMEnsureWindow();

    gIsTransitionRunning = YES;
    if (opening && !CGRectIsEmpty(iconFrame)) {
        gLastOpenedIconFrame = iconFrame;
        if (iconImage) {
            gLastOpenedIconImage = iconImage;
        }
    }

    CGRect screen = gOverlayWindow.bounds;
    CGFloat duration = 0.35;

    CALayer *backdrop = [CALayer layer];
    backdrop.frame = screen;
    backdrop.backgroundColor = [UIColor clearColor].CGColor;
    [gOverlayWindow.layer addSublayer:backdrop];

    CAShapeLayer *maskShape = [CAShapeLayer layer];
    maskShape.frame = screen;

    CALayer *iconLayer = [CALayer layer];
    iconLayer.frame = screen;
    iconLayer.contentsGravity = kCAGravityResizeAspectFill;

    UIImage *targetImg = opening ? iconImage : (gLastOpenedIconImage ? gLastOpenedIconImage : iconImage);
    if (targetImg) {
        iconLayer.contents = (__bridge id)targetImg.CGImage;
    } else {
        iconLayer.backgroundColor = [UIColor clearColor].CGColor;
    }
    iconLayer.mask = maskShape;
    [gOverlayWindow.layer addSublayer:iconLayer];

    CGRect activeFrame = opening ? iconFrame : (CGRectIsEmpty(gLastOpenedIconFrame) ? CGRectMake(screen.size.width/2 - 30, screen.size.height - 150, 60, 60) : gLastOpenedIconFrame);
    NSArray *paths = LMBuildKeyframePaths(activeFrame, screen, opening);

    CAKeyframeAnimation *pathAnim = [CAKeyframeAnimation animationWithKeyPath:@"path"];
    pathAnim.values = paths;
    pathAnim.duration = duration;
    pathAnim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    pathAnim.fillMode = kCAFillModeForwards;
    pathAnim.removedOnCompletion = NO;

    maskShape.path = (__bridge CGPathRef)paths.lastObject;
    [maskShape addAnimation:pathAnim forKey:@"morph"];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LMForceClearOverlay();
        if (completion) {
            completion();
        }
    });
}

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
        if (!CGRectIsEmpty(frameInWindow) && frameInWindow.size.width >= 10) {
            UIImage *iconImage = LMRenderIconImage(self);

            LMRunTransition(frameInWindow, iconImage, YES, ^{});

            %orig;
            return;
        }
    } @catch (NSException *e) {}
    %orig;
}

%end

// Hook bắt toàn bộ sự kiện vuốt đóng app (gesture dismiss / deactivating / back to homescreen) của hệ thống
%hook SBMainWorkspace

- (void)executeTransitionRequest:(id)request withCompletion:(id)completion {
    @try {
        NSString *reqDesc = [request description];
        if ([reqDesc containsString:@"Deactivating"] || [reqDesc containsString:@"dismiss"] || [reqDesc containsString:@"to-homescreen"] || [reqDesc containsString:@"home"] || [reqDesc containsString:@"unlocked"]) {
            if (!gIsTransitionRunning && !CGRectIsEmpty(gLastOpenedIconFrame)) {
                LMRunTransition(gLastOpenedIconFrame, gLastOpenedIconImage, NO, nil);
            }
        }
    } @catch (NSException *e) {}
    %orig;
}

%end

%ctor {
    LMLog(@"=== LiquidMorph v12.6 Full Gesture Fixed Loaded ===");
}
