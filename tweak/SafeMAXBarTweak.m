#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Simple runtime tweak to style the bottom tab bar like Telegram:
// - icons only
// - floating dark rounded bar with blur
// - slightly larger icons

static void styleTabBar(UITabBar *tabBar) {
    if (!tabBar) return;

    // Hide labels
    for (UITabBarItem *item in tabBar.items) {
        item.title = nil;
        item.imageInsets = UIEdgeInsetsMake(6, 0, -6, 0);
    }

    // Appearance
    UITabBarAppearance *appearance = [[UITabBarAppearance alloc] init];
    [appearance configureWithTransparentBackground];

    // Dark blur background
    appearance.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    appearance.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.65];

    // Selected / unselected colors
    appearance.stackedLayoutAppearance.selected.iconColor = [UIColor whiteColor];
    appearance.stackedLayoutAppearance.normal.iconColor = [UIColor colorWithWhite:1.0 alpha:0.55];

    tabBar.standardAppearance = appearance;
    if (@available(iOS 15.0, *)) {
        tabBar.scrollEdgeAppearance = appearance;
    }

    // Floating style
    tabBar.layer.cornerRadius = 24;
    tabBar.layer.masksToBounds = YES;
    tabBar.layer.borderWidth = 0.5;
    tabBar.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;

    // Adjust frame to float above bottom
    CGRect frame = tabBar.frame;
    CGFloat inset = 16;
    frame.origin.x = inset;
    frame.size.width = tabBar.superview.bounds.size.width - inset * 2;
    frame.origin.y = tabBar.superview.bounds.size.height - frame.size.height - 20;
    tabBar.frame = frame;
    tabBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
}

static void applyToAllTabBars(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            UIViewController *root = window.rootViewController;
            if ([root isKindOfClass:[UITabBarController class]]) {
                styleTabBar(((UITabBarController *)root).tabBar);
            }
            // Walk presented / children
            NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
            while (stack.count) {
                UIViewController *vc = stack.lastObject;
                [stack removeLastObject];
                if ([vc isKindOfClass:[UITabBarController class]]) {
                    styleTabBar(((UITabBarController *)vc).tabBar);
                }
                [stack addObjectsFromArray:vc.childViewControllers];
                if (vc.presentedViewController) [stack addObject:vc.presentedViewController];
            }
        }
    });
}

// Hook to re-apply when tab bar appears
static void (*orig_viewDidAppear)(id, SEL, BOOL);
static void swizzled_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_viewDidAppear(self, _cmd, animated);
    if ([self isKindOfClass:[UITabBarController class]]) {
        styleTabBar(((UITabBarController *)self).tabBar);
    }
}

__attribute__((constructor))
static void init(void) {
    // Delay to let the app finish launching
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        applyToAllTabBars();

        // Swizzle viewDidAppear on UITabBarController
        Class cls = [UITabBarController class];
        Method m = class_getInstanceMethod(cls, @selector(viewDidAppear:));
        if (m) {
            orig_viewDidAppear = (void *)method_getImplementation(m);
            method_setImplementation(m, (IMP)swizzled_viewDidAppear);
        }
    });

    // Also re-apply periodically in case the app recreates the bar
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ applyToAllTabBars(); });
}
