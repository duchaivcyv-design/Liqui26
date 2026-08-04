#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

// ==========================================
// 1. INTERFACE DECLARATIONS
// ==========================================

@interface SBIconView : UIView
@property (nonatomic, strong) id icon;
- (UIImage *)generateSnapshot;
@end

@interface SBUIAnimationController : NSObject
@property (nonatomic, readonly) UIView *containerView;
@end

// ==========================================
// 2. GLOBAL VARIABLES & STATE TRACKING
// ==========================================

static UIWindow *gLiquidMorphWindow = nil;
static CGRect gCachedIconFrame = CGRectZero;
static UIImage *gCachedIconImage = nil;
static BOOL gIsPerformingCustomTransition = NO;

#define LM_LOG(fmt, ...) NSLog(@"[LiquidMorph26_Full] " fmt, ##__VA_ARGS__)

// ==========================================
// 3. OVERLAY WINDOW MANAGEMENT
// ==========================================

static void LMInitializeOverlayWindow(void) {
    if (!gLiquidMorphWindow) {
        gLiquidMorphWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        gLiquidMorphWindow.windowLevel = UIWindowLevelStatusBar + 3000;
        gLiquidMorphWindow.userInteractionEnabled = NO;
        gLiquidMorphWindow.backgroundColor = [UIColor clearColor];
    }
    
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                gLiquidMorphWindow.windowScene = (UIScene *)scene;
                break;
            }
        }
    }
    gLiquidMorphWindow.hidden = NO;
}

static void LMDestroyOverlayWindow(void) {
    if (gLiquidMorphWindow) {
        gLiquidMorphWindow.hidden = YES;
        for (CALayer *sublayer in [gLiquidMorphWindow.layer.sublayers copy]) {
            [sublayer removeFromSuperlayer];
        }
    }
    gIsPerformingCustomTransition = NO;
}

// ==========================================
// 4. ICON SNAPSHOT HELPER
// ==========================================

static UIImage *LMExtractIconImageSafe(SBIconView *iconView) {
    if (!iconView) return nil;
    @try {
        if ([iconView respondsToSelector:@selector(generateSnapshot)]) {
            UIImage *snapshot = [iconView generateSnapshot];
            if (snapshot) return snapshot;
        }
        UIGraphicsBeginImageContextWithOptions(iconView.bounds.size, NO, [UIScreen mainScreen].scale);
        [iconView drawViewHierarchyInRect:iconView.bounds afterScreenUpdates:NO];
        UIImage *snapshot = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (snapshot) return snapshot;
    } @catch (NSException *exception) {
        LM_LOG(@"Error extracting icon image: %@", exception.reason);
    }
    return nil;
}

// ==========================================
// 5. iOS 26 FLUID MORPH PATH ALGORITHM
// ==========================================

static CGPathRef LMCreateFluidMorphPath(CGRect rect, CGFloat cornerRadius, CGFloat progress) {
    CGMutablePathRef path = CGPathCreateMutable();
    CGFloat w = rect.size.width;
    CGFloat h = rect.size.height;
    CGFloat x = rect.origin.x;
    CGFloat y = rect.origin.y;

    CGFloat r = MIN(cornerRadius, MIN(w, h) * 0.5);
    CGFloat fluidBulge = sinf(progress * M_PI) * 16.0;

    CGPathMoveToPoint(path, NULL, x + r, y);
    CGPathAddQuadCurveToPoint(path, NULL, x + w * 0.5, y - fluidBulge, x + w - r, y);
    CGPathAddArcToPoint(path, NULL, x + w, y, x + w, y + r, r);
    
    CGPathAddQuadCurveToPoint(path, NULL, x + w + fluidBulge, y + h * 0.5, x + w, y + h - r);
    CGPathAddArcToPoint(path, NULL, x + w, y + h, x + w - r, y + h, r);
    
    CGPathAddQuadCurveToPoint(path, NULL, x + w * 0.5, y + h + fluidBulge, x + r, y + h);
    CGPathAddArcToPoint(path, NULL, x, y + h, x, y + h - r, r);
    
    CGPathAddQuadCurveToPoint(path, NULL, x - fluidBulge, y + h * 0.5, x, y + r);
    CGPathAddArcToPoint(path, NULL, x, y, x + r, y, r);

    CGPathCloseSubpath(path);
    return path;
}

// ==========================================
// 6. ANIMATION PLAYER ENGINE
// ==========================================

static void LMExecuteTransitionAnimation(CGRect targetIconFrame, UIImage *iconImage, BOOL isOpening) {
    LMInitializeOverlayWindow();
    gIsPerformingCustomTransition = YES;

    CGRect screenBounds = gLiquidMorphWindow.bounds;
    CGFloat animationDuration = 0.48;

    CAShapeLayer *maskShapeLayer = [CAShapeLayer layer];
    maskShapeLayer.frame = screenBounds;

    CALayer *contentLayer = [CALayer layer];
    contentLayer.frame = screenBounds;
    contentLayer.contentsGravity = kCAGravityResizeAspectFill;
    
    if (iconImage) {
        contentLayer.contents = (__bridge id)iconImage.CGImage;
    }
    contentLayer.mask = maskShapeLayer;
    [gLiquidMorphWindow.layer addSublayer:contentLayer];

    NSInteger totalSteps = 12;
    NSMutableArray *pathArray = [NSMutableArray arrayWithCapacity:totalSteps + 1];

    CGRect startRect = isOpening ? targetIconFrame : screenBounds;
    CGRect endRect = isOpening ? screenBounds : targetIconFrame;
    CGFloat startRadius = isOpening ? 14.0 : 0.0;
    CGFloat endRadius = isOpening ? 44.0 : 14.0;

    for (NSInteger step = 0; step <= totalSteps; step++) {
        CGFloat progressValue = (CGFloat)step / (CGFloat)totalSteps;
        
        CGFloat currentX = startRect.origin.x + (endRect.origin.x - startRect.origin.x) * progressValue;
        CGFloat currentY = startRect.origin.y + (endRect.origin.y - startRect.origin.y) * progressValue;
        CGFloat currentW = startRect.size.width + (endRect.size.width - startRect.size.width) * progressValue;
        CGFloat currentH = startRect.size.height + (endRect.size.height - startRect.size.height) * progressValue;
        CGRect currentFrameRect = CGRectMake(currentX, currentY, currentW, currentH);

        CGFloat currentRadiusValue = startRadius + (endRadius - startRadius) * progressValue;
        CGPathRef pathReference = LMCreateFluidMorphPath(currentFrameRect, currentRadiusValue, progressValue);
        [pathArray addObject:(__bridge_transfer id)pathReference];
    }

    CAKeyframeAnimation *morphAnimation = [CAKeyframeAnimation animationWithKeyPath:@"path"];
    morphAnimation.values = pathArray;
    morphAnimation.duration = animationDuration;
    morphAnimation.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.3 :1.0];
    morphAnimation.fillMode = kCAFillModeForwards;
    morphAnimation.removedOnCompletion = NO;

    maskShapeLayer.path = (__bridge CGPathRef)pathArray.lastObject;
    [maskShapeLayer addAnimation:morphAnimation forKey:@"iOS26FluidMorphKey"];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(animationDuration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LMDestroyOverlayWindow();
    });
}

// ==========================================
// 7. HOOK IMPLEMENTATIONS
// ==========================================

%hook SBIconView

- (void)_handleTap {
    @try {
        if (self.window) {
            gCachedIconFrame = [self.window convertRect:self.bounds fromView:self];
            gCachedIconImage = LMExtractIconImageSafe(self);
            LMExecuteTransitionAnimation(gCachedIconFrame, gCachedIconImage, YES);
        }
    } @catch (NSException *exception) {
        LM_LOG(@"Exception in _handleTap: %@", exception.reason);
    }
    %orig;
}

%end

%hook SBUIAnimationController

- (void)_willBegin {
    %orig;
    if (gIsPerformingCustomTransition) {
        @try {
            UIView *container = [self containerView];
            if (container) {
                container.hidden = YES;
                container.alpha = 0.0;
            }
        } @catch (NSException *exception) {}
    }
}

- (void)_cleanupAnimation {
    %orig;
    @try {
        UIView *container = [self containerView];
        if (container) {
            container.hidden = NO;
            container.alpha = 1.0;
        }
    } @catch (NSException *exception) {}
}

%end

%hook SBWorkspaceApplicationSceneTransitionContext

- (void)setAnimationDisabled:(BOOL)disabled {
    if (gCachedIconFrame.size.width > 0 && !gIsPerformingCustomTransition) {
        LMExecuteTransitionAnimation(gCachedIconFrame, gCachedIconImage, NO);
    }
    %orig(disabled);
}

%end

// ==========================================
// 8. MODULE CONSTRUCTOR
// ==========================================

%ctor {
    @autoreleasepool {
        LM_LOG(@"LiquidMorph iOS 26 Full Extension Initialized Successfully.");
    }
}
