#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

// ==========================================
// 1. KHAI BÁO INTERFACE (SỬA LỖI FORWARD DECLARATION)
// ==========================================

@interface SBIconView : UIView
@property (nonatomic, strong) id icon;
@end

// Khai báo class đầy đủ thay vì dùng @class
@interface SBUIAnimationController : NSObject
- (id)valueForKey:(NSString *)key;
@end

@interface SBUIWorkspaceAnimationController : SBUIAnimationController
@end

@interface SBWorkspaceApplicationSceneTransitionContext : NSObject
@end

// ==========================================
// 2. BIẾN TOÀN CỤC & TÙY CHỈNH
// ==========================================

static UIWindow *gOverlayWindow = nil;
static CGRect gLastTouchedIconFrame = CGRectZero;
static UIImage *gLastTouchedIconImage = nil;
static BOOL gIsCustomAnimating = NO;

#define LMLog(fmt, ...) NSLog(@"[LiquidMorph26] " fmt, ##__VA_ARGS__)

// ==========================================
// 3. CORE ANIMATION ENGINE (CHUẨN iOS 26 - 60 FPS)
// ==========================================

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

// Tạo Path Morphing uốn cong 4 cạnh mềm mại kiểu iOS 26
static CGPathRef LMCreateiOS26MorphPath(CGRect rect, CGFloat cornerRadius, CGFloat progress) {
    CGMutablePathRef path = CGPathCreateMutable();
    CGFloat w = rect.size.width;
    CGFloat h = rect.size.height;
    CGFloat x = rect.origin.x;
    CGFloat y = rect.origin.y;

    CGFloat r = MIN(cornerRadius, MIN(w, h) * 0.5);
    
    // Hiệu ứng phồng nhẹ (Fluid Bulge) giữa các cạnh
    CGFloat bulge = sinf(progress * M_PI) * 16.0;

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
    CGFloat duration = 0.52; // Tốc độ tiêu chuẩn mượt mà chuẩn iOS 26

    CAShapeLayer *maskLayer = [CAShapeLayer layer];
    maskLayer.frame = screenBounds;

    CALayer *contentLayer = [CALayer layer];
    contentLayer.frame = screenBounds;
    contentLayer.contentsGravity = kCAGravityResizeAspectFill;
    
    if (iconImage) {
        contentLayer.contents = (__bridge id)iconImage.CGImage;
    } else {
        contentLayer.backgroundColor = [UIColor colorWithRed:0.07 green:0.47 blue:0.97 alpha:1.0].CGColor;
    }
    contentLayer.mask = maskLayer;
    [gOverlayWindow.layer addSublayer:contentLayer];

    NSInteger steps = 12; // 12 keyframes tối ưu GPU render 60/120 FPS
    NSMutableArray *pathValues = [NSMutableArray arrayWithCapacity:steps + 1];

    CGRect startRect = isOpening ? iconFrame : screenBounds;
    CGRect endRect = isOpening ? screenBounds : iconFrame;
    CGFloat startRadius = isOpening ? 14.0 : 0.0;
    CGFloat endRadius = isOpening ? 48.0 : 14.0;

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

// ==========================================
// 4. HOOKS (AN TOÀN - KHÔNG SAFEMODE)
// ==========================================

%hook SBIconView

- (void)_handleTap {
    @try {
        if (self.window) {
            gLastTouchedIconFrame = [self.window convertRect:self.bounds fromView:self];
            if (self.layer.contents) {
                gLastTouchedIconImage = [UIImage imageWithCGImage:(__bridge CGImageRef)self.layer.contents];
            } else {
                gLastTouchedIconImage = nil;
            }
            
            LMPerformiOS26Transition(gLastTouchedIconFrame, gLastTouchedIconImage, YES);
        }
    } @catch (NSException *e) {}
    %orig;
}

%end

// Hook ẩn animation gốc bằng ivar an toàn (Tránh Exception Safe Mode)
%hook SBUIAnimationController

- (void)_willBegin {
    %orig;
    if (gIsCustomAnimating) {
        @try {
            Ivar ivar = class_getInstanceVariable([self class], "_containerView");
            if (!ivar) {
                ivar = class_getInstanceVariable(class_getSuperclass([self class]), "_containerView");
            }
            if (ivar) {
                UIView *containerView = object_getIvar(self, ivar);
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
        Ivar ivar = class_getInstanceVariable([self class], "_containerView");
        if (!ivar) {
            ivar = class_getInstanceVariable(class_getSuperclass([self class]), "_containerView");
        }
        if (ivar) {
            UIView *containerView = object_getIvar(self, ivar);
            if ([containerView isKindOfClass:[UIView class]]) {
                containerView.alpha = 1.0;
            }
        }
    } @catch (NSException *e) {}
}

%end

// Hook bắt sự kiện Thoát App
%hook SBWorkspaceApplicationSceneTransitionContext

- (void)setAnimationDisabled:(BOOL)disabled {
    if (gLastTouchedIconFrame.size.width > 0 && !gIsCustomAnimating) {
        LMPerformiOS26Transition(gLastTouchedIconFrame, gLastTouchedIconImage, NO);
    }
    %orig(disabled);
}

%end

// ==========================================
// 5. INITIALIZER
// ==========================================

%ctor {
    @autoreleasepool {
        LMLog(@"LiquidMorph iOS 26 loaded cleanly without compilation errors.");
    }
}
