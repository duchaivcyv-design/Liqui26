#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

// ==========================================
// 1. INTERFACE & STRUCTS
// ==========================================

@interface SBIconView : UIView
@property (nonatomic, strong) id icon;
@end

@interface SBWorkspaceApplicationSceneTransitionContext : NSObject
@end

// ==========================================
// 2. GLOBAL VARIABLES
// ==========================================

static UIWindow *gOverlayWindow = nil;
static CGRect gLastTouchedIconFrame = CGRectZero;
static UIImage *gLastTouchedIconImage = nil;
static BOOL gIsCustomAnimating = NO;

#define LMLog(fmt, ...) NSLog(@"[LiquidMorph26] " fmt, ##__VA_ARGS__)

// ==========================================
// 3. CORE ANIMATION ENGINE (OPTIMIZED 60FPS)
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

// Tạo Path Morphing 4 điểm mềm dạng Giọt nước / iOS 26
static CGPathRef LMCreateMorphPath(CGRect rect, CGFloat cornerRadius, CGFloat expansionFactor) {
    CGMutablePathRef path = CGPathCreateMutable();
    CGFloat w = rect.size.width;
    CGFloat h = rect.size.height;
    CGFloat x = rect.origin.x;
    CGFloat y = rect.origin.y;

    // Giới hạn bán kính góc bo
    CGFloat r = MIN(cornerRadius, MIN(w, h) * 0.5);
    
    // Tạo độ phồng nhẹ (Morph bulge) ở giữa các cạnh khi mở/đóng
    CGFloat bulge = sinf(expansionFactor * M_PI) * 18.0;

    CGPathMoveToPoint(path, NULL, x + r, y);
    CGPathAddQuadCurveToPoint(path, NULL, x + w/2, y - bulge, x + w - r, y);
    CGPathAddArcToPoint(path, NULL, x + w, y, x + w, y + r, r);
    
    CGPathAddQuadCurveToPoint(path, NULL, x + w + bulge, y + h/2, x + w, y + h - r);
    CGPathAddArcToPoint(path, NULL, x + w, y + h, x + w - r, y + h, r);
    
    CGPathAddQuadCurveToPoint(path, NULL, x + w/2, y + h + bulge, x + r, y + h);
    CGPathAddArcToPoint(path, NULL, x, y + h, x, y + h - r, r);
    
    CGPathAddQuadCurveToPoint(path, NULL, x - bulge, y + h/2, x, y + r);
    CGPathAddArcToPoint(path, NULL, x, y, x + r, y, r);

    CGPathCloseSubpath(path);
    return path;
}

// Xử lý chuyển cảnh iOS 26 siêu mượt
static void LMPerformiOS26Transition(CGRect iconFrame, UIImage *iconImage, BOOL isOpening) {
    LMEnsureOverlayWindow();
    gIsCustomAnimating = YES;

    CGRect screenBounds = gOverlayWindow.bounds;
    CGFloat duration = 0.52; // Tốc độ tiêu chuẩn iOS 26 (vừa đủ mượt, không quá nhanh/chậm)

    // Mask Layer chính cho Morphing
    CAShapeLayer *maskLayer = [CAShapeLayer layer];
    maskLayer.frame = screenBounds;

    CALayer *contentLayer = [CALayer layer];
    contentLayer.frame = screenBounds;
    contentLayer.contentsGravity = kCAGravityResizeAspectFill;
    
    if (iconImage) {
        contentLayer.contents = (__bridge id)iconImage.CGImage;
    } else {
        contentLayer.backgroundColor = [UIColor systemBlueColor].CGColor;
    }
    contentLayer.mask = maskLayer;
    [gOverlayWindow.layer addSublayer:contentLayer];

    // Tạo Keyframes Path cho Morph
    NSInteger steps = 12; // 12 keyframes là tối ưu nhất cho GPU render 60 FPS
    NSMutableArray *pathValues = [NSMutableArray arrayWithCapacity:steps + 1];

    CGRect startRect = isOpening ? iconFrame : screenBounds;
    CGRect endRect = isOpening ? screenBounds : iconFrame;
    CGFloat startRadius = isOpening ? 14.0 : 0.0;
    CGFloat endRadius = isOpening ? 48.0 : 14.0;

    for (NSInteger i = 0; i <= steps; i++) {
        CGFloat progress = (CGFloat)i / (CGFloat)steps;
        
        // Tính vị trí Frame nội suy mượt
        CGFloat currentX = startRect.origin.x + (endRect.origin.x - startRect.origin.x) * progress;
        CGFloat currentY = startRect.origin.y + (endRect.origin.y - startRect.origin.y) * progress;
        CGFloat currentW = startRect.size.width + (endRect.size.width - startRect.size.width) * progress;
        CGFloat currentH = startRect.size.height + (endRect.size.height - startRect.size.height) * progress;
        CGRect currentRect = CGRectMake(currentX, currentY, currentW, currentH);

        CGFloat currentRadius = startRadius + (endRadius - startRadius) * progress;
        
        CGPathRef p = LMCreateMorphPath(currentRect, currentRadius, progress);
        [pathValues addObject:(__bridge_transfer id)p];
    }

    // Animation Keyframe với Spring Timing
    CAKeyframeAnimation *morphAnim = [CAKeyframeAnimation animationWithKeyPath:@"path"];
    morphAnim.values = pathValues;
    morphAnim.duration = duration;
    morphAnim.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.16 :1.0 :0.3 :1.0]; // iOS Spring Curve
    morphAnim.fillMode = kCAFillModeForwards;
    morphAnim.removedOnCompletion = NO;

    maskLayer.path = (__bridge CGPathRef)pathValues.lastObject;
    [maskLayer addAnimation:morphAnim forKey:@"iOS26Morph"];

    // Tự dọn dẹp sau khi hết hiệu ứng
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LMClearOverlay();
    });
}

// ==========================================
// 4. HOOKS: BẮT SỰ KIỆN MỞ & THOÁT APP (SẠCH GỐC)
// ==========================================

// Hook chạm Icon
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
            
            // Kích hoạt animation mở app iOS 26
            LMPerformiOS26Transition(gLastTouchedIconFrame, gLastTouchedIconImage, YES);
        }
    } @catch (NSException *e) {}
    %orig;
}

%end

// Hook ẩn hoàn toàn Animation gốc của hệ thống
%hook SBUIAnimationController

- (void)_willBegin {
    %orig;
    if (gIsCustomAnimating) {
        @try {
            UIView *containerView = [self valueForKey:@"_containerView"];
            if (containerView) {
                containerView.alpha = 0.0; // Ẩn hoàn toàn gốc
            }
        } @catch (NSException *e) {}
    }
}

- (void)_cleanupAnimation {
    %orig;
    @try {
        UIView *containerView = [self valueForKey:@"_containerView"];
        if (containerView) {
            containerView.alpha = 1.0;
        }
    } @catch (NSException *e) {}
}

%end

// Hook bắt sự kiện Thoát App (Vuốt Home / Bấm Home)
%hook SBWorkspaceApplicationSceneTransitionContext

- (void)setAnimationDisabled:(BOOL)disabled {
    // Nếu đang thoát về HomeScreen, chạy hiệu ứng thu nhỏ
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
        LMLog(@"LiquidMorph iOS 26 Loaded successfully.");
    }
}
