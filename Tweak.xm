#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

@interface SBIconView : UIView
@property (nonatomic, strong) id icon;
- (UIImage *)generateSnapshot;
@end

@interface SBUIAnimationController : NSObject
@end

static UIWindow *gOverlayWindow = nil;
static CGRect gLastTouchedIconFrame = CGRectZero;
static UIImage *gLastTouchedIconImage = nil;
static BOOL gIsCustomAnimating = NO;

#define LMLog(fmt, ...) NSLog(@"[LiquidMorph26] " fmt, ##__VA_ARGS__)

static void LMEnsureOverlayWindow(void) {
    if (!gOverlayWindow) {
        gOverlayWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        gOverlayWindow.windowLevel = UIWindowLevelStatusBar + 2000;
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

static void LMClearOverlay(void) {
    if (gOverlayWindow) {
        gOverlayWindow.hidden = YES;
        for (CALayer *layer in [gOverlayWindow.layer.sublayers copy]) {
            [layer removeFromSuperlayer];
        }
    }
    gIsCustomAnimating = NO;
}

static UIImage *LMExtractRealIconImage(SBIconView *iconView) {
    if (!iconView) return nil;
    @try {
        if ([iconView respondsToSelector:@selector(generateSnapshot)]) {
            UIImage *img = [iconView generateSnapshot];
            if (img) return img;
        }
        UIGraphicsBeginImageContextWithOptions(iconView.bounds.size, NO, [UIScreen mainScreen].scale);
        [iconView drawViewHierarchyInRect:iconView.bounds afterScreenUpdates:NO];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (img) return img;
    } @catch (NSException *e) {}
    return nil;
}

static CGPathRef LMCreateiOS26MorphPath(CGRect rect, CGFloat cornerRadius, CGFloat progress) {
    CGMutablePathRef path = CGPathCreateMutable();
    CGFloat w = rect.size.width;
    CGFloat h = rect.size.height;
    CGFloat x = rect.origin.x;
    CGFloat y = rect.origin.y;

    CGFloat r = MIN(cornerRadius, MIN(w, h) * 0.5);
    CGFloat bulge = sinf(progress * M_PI) * 18.0;

    CGPathMoveToPoint(path, NULL, x + r, y);
    CGPathAddQuadCurveToPoint(path, NULL, x + w / 2.0, y - bulge, x + w - r, y);
    CGPathAddArcToPoint(path, NULL, x + w, y, x + w, y + r, r);
    
    CGPathAddQuadCurveToPoint(path, NULL, x + w + bulge, y + h / 2.0, x + w, y + h - r);
    CGPathAddArcToPoint(path, NULL, x + w, y + h, x + w - r, y + h, r);
    
    CGPathAddQuadCurveToPoint(path, NULL, x + w / 2.0, y + h + bulge, x + r, y + h);
    CGPathAddArcToPoint(path, NULL, x, y + h, x, y + h - r, r);
    
    CGPathAddQuadCurveToPoint(path, NULL, x - bulge, y + h / 2.0, x, y + r);
    CGPathAddArcToPoint(path, NULL, x, y, x + r, y, r);

    CGPathCloseSubpath(path);
    return path;
}

static void LMPerformiOS26Transition(CGRect iconFrame, UIImage *iconImage, BOOL isOpening) {
    LMEnsureOverlayWindow();
    gIsCustomAnimating = YES;

    CGRect screenBounds = gOverlayWindow.bounds;
    CGFloat duration = 0.50;

    CAShapeLayer *maskLayer = [CAShapeLayer layer];
    maskLayer.frame = screenBounds;

    CALayer *contentLayer = [CALayer layer];
    contentLayer.frame = screenBounds;
    contentLayer.contentsGravity = kCAGravityResizeAspectFill;
    
    if (iconImage) {
        contentLayer.contents = (__bridge id)iconImage.CGImage;
    }
    contentLayer.mask = maskLayer;
    [gOverlayWindow.layer addSublayer:contentLayer];

    NSInteger steps = 12;
    NSMutableArray *pathValues = [NSMutableArray arrayWithCapacity:steps + 1];

    CGRect startRect = isOpening ? iconFrame : screenBounds;
    CGRect endRect = isOpening ? screenBounds : iconFrame;
    CGFloat startRadius = isOpening ? 14.0 : 0.0;
    CGFloat endRadius = isOpening ? 44.0 : 14.0;

    for (NSInteger i = 0; i <= steps; i++) {
        CGFloat progress = (CGFloat)i / (CGFloat)steps;
        
        CGFloat currentX = startRect.origin.x + (endRect.origin.x - startRect.origin.x) * progress;
        CGFloat currentY = startRect.origin.y + (endRect.origin.y - startRect.origin.y) * progress;
        CGFloat currentW = startRect.size.width + (endRect.size.width - startRect.size.width) * progress;
        CGFloat currentH = startRect.size.height + (endRect.size.height - startRect.size.height) * progress;
        CGRect currentRect = CGRectMake(currentX, currentY, currentW, currentH);

        CGFloat currentRadius = startRadius + (endRadius - startRadius) * progress;
        CGPathRef p = LMCreateiOS26MorphPath(currentRect, currentRadius, progress);
        [pathValues addObject:(__bridge_transfer id)p];
    }

    CAKeyframeAnimation *morphAnim = [CAKeyframeAnimation animationWithKeyPath:@"path"];
    morphAnim.values = pathValues;
    morphAnim.duration = duration;
    morphAnim.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.3 :1.0];
    morphAnim.fillMode = kCAFillModeForwards;
    morphAnim.removedOnCompletion = NO;

    maskLayer.path = (__bridge CGPathRef)pathValues.lastObject;
    [maskLayer addAnimation:morphAnim forKey:@"iOS26Morph"];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LMClearOverlay();
    });
}

%hook SBIconView

- (void)_handleTap {
    @try {
        if (self.window) {
            gLastTouchedIconFrame = [self.window convertRect:self.bounds fromView:self];
            gLastTouchedIconImage = LMExtractRealIconImage(self);
            LMPerformiOS26Transition(gLastTouchedIconFrame, gLastTouchedIconImage, YES);
        }
    } @catch (NSException *e) {}
    %orig;
}

%end

%hook SBUIAnimationController

- (void)_willBegin {
    %orig;
    @try {
        Ivar ivar = class_getInstanceVariable([self class], "_containerView");
        if (!ivar) {
            ivar = class_getInstanceVariable(class_getSuperclass([self class]), "_containerView");
        }
        if (ivar) {
            UIView *containerView = object_getIvar(self, ivar);
            if ([containerView isKindOfClass:[UIView class]]) {
                containerView.hidden = YES;
                containerView.alpha = 0.0;
            }
        }
    } @catch (NSException *e) {}
}

- (void)_cleanupAnimation {
    %orig;
    @try {
        Ivar ivar = class_getInstanceVariable([self class], "_containerView");
        if (!ivar) {
            ivar = class_getInstanceVariable(class_getSuperclass([self class]), "_containerView");
        }
        if (ivar) {
            UIView *containerView = object_getIvar(self, ivar);
            if ([containerView isKindOfClass:[UIView class]]) {
                containerView.hidden = NO;
                containerView.alpha = 1.0;
            }
        }
    } @catch (NSException *e) {}
}

%end

%hook SBWorkspaceApplicationSceneTransitionContext

- (void)setAnimationDisabled:(BOOL)disabled {
    if (gLastTouchedIconFrame.size.width > 0 && !gIsCustomAnimating) {
        LMPerformiOS26Transition(gLastTouchedIconFrame, gLastTouchedIconImage, NO);
    }
    %orig(disabled);
}

%end

%ctor {
    @autoreleasepool {
        LMLog(@"LiquidMorph iOS 26 Clean Edition loaded.");
    }
}
