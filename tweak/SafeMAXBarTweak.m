#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Runtime tweak for SafeMAX bottom tab bar:
// - Labels restored by default
// - Proper floating Liquid Glass-style dock (iOS 26 inspired)
// - Settings button to edit dock options (persisted)

static NSString *const kShowLabelsKey = @"SafeMAX_ShowLabels";
static NSString *const kFloatingKey = @"SafeMAX_FloatingDock";
static NSString *const kCornerRadiusKey = @"SafeMAX_DockRadius";

static BOOL showLabels(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kShowLabelsKey] ||
           ![[NSUserDefaults standardUserDefaults] objectForKey:kShowLabelsKey]; // default YES
}

static BOOL floatingDock(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kFloatingKey] ||
           ![[NSUserDefaults standardUserDefaults] objectForKey:kFloatingKey]; // default YES
}

static CGFloat dockRadius(void) {
    CGFloat r = [[NSUserDefaults standardUserDefaults] floatForKey:kCornerRadiusKey];
    return r > 0 ? r : 28.0;
}

static void styleTabBar(UITabBar *tabBar) {
    if (!tabBar) return;

    BOOL labels = showLabels();
    BOOL floating = floatingDock();

    for (UITabBarItem *item in tabBar.items) {
        if (!labels) {
            item.title = nil;
            item.imageInsets = UIEdgeInsetsMake(6, 0, -6, 0);
        } else {
            // Restore default title positioning
            item.imageInsets = UIEdgeInsetsZero;
            // Titles are managed by the system; we just don't nil them
        }
    }

    UITabBarAppearance *appearance = [[UITabBarAppearance alloc] init];
    [appearance configureWithTransparentBackground];

    // iOS 26-style Liquid Glass
    appearance.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    appearance.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.55];

    appearance.stackedLayoutAppearance.selected.iconColor = [UIColor whiteColor];
    appearance.stackedLayoutAppearance.normal.iconColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    appearance.stackedLayoutAppearance.selected.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor whiteColor]};
    appearance.stackedLayoutAppearance.normal.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.6]};

    tabBar.standardAppearance = appearance;
    if (@available(iOS 15.0, *)) {
        tabBar.scrollEdgeAppearance = appearance;
    }

    // Floating style
    tabBar.layer.cornerRadius = floating ? dockRadius() : 0;
    tabBar.layer.masksToBounds = floating;
    tabBar.layer.borderWidth = floating ? 0.5 : 0;
    tabBar.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;

    // Shadow for more glass float
    tabBar.layer.shadowColor = [UIColor blackColor].CGColor;
    tabBar.layer.shadowOpacity = floating ? 0.35 : 0;
    tabBar.layer.shadowOffset = CGSizeMake(0, 4);
    tabBar.layer.shadowRadius = 12;

    if (floating) {
        CGRect frame = tabBar.frame;
        CGFloat inset = 12;
        CGFloat bottomInset = 16;
        frame.origin.x = inset;
        frame.size.width = tabBar.superview.bounds.size.width - inset * 2;
        frame.origin.y = tabBar.superview.bounds.size.height - frame.size.height - bottomInset;
        tabBar.frame = frame;
        tabBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    }
}

static void applyToAllTabBars(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            UIViewController *root = window.rootViewController;
            NSMutableArray *stack = [NSMutableArray array];
            if (root) [stack addObject:root];
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

// --- Settings injection ---
static void (*orig_viewDidAppear)(id, SEL, BOOL);
static void swizzled_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_viewDidAppear(self, _cmd, animated);

    if ([self isKindOfClass:[UITabBarController class]]) {
        styleTabBar(((UITabBarController *)self).tabBar);
    }

    // Try to detect settings screen and inject "Редактировать док" button
    if ([self isKindOfClass:[UIViewController class]]) {
        UIViewController *vc = (UIViewController *)self;
        // Look for table views that contain known settings labels
        for (UIView *sub in vc.view.subviews) {
            if ([sub isKindOfClass:[UITableView class]]) {
                UITableView *tv = (UITableView *)sub;
                // Simple heuristic: if we see "Оформление" or "Язык приложения" in visible cells, inject
                BOOL isSettings = NO;
                for (UITableViewCell *cell in tv.visibleCells) {
                    if ([cell.textLabel.text containsString:@"Оформление"] ||
                        [cell.textLabel.text containsString:@"Язык приложения"] ||
                        [cell.textLabel.text containsString:@"Помощь"]) {
                        isSettings = YES;
                        break;
                    }
                }
                if (isSettings && ![objc_getAssociatedObject(tv, "safeMAXInjected") boolValue]) {
                    objc_setAssociatedObject(tv, "safeMAXInjected", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    // Insert a new section or just show an alert for now via a floating button
                    UIButton *editBtn = [UIButton buttonWithType:UIButtonTypeSystem];
                    [editBtn setTitle:@"Редактировать док" forState:UIControlStateNormal];
                    editBtn.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
                    editBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.9];
                    editBtn.layer.cornerRadius = 12;
                    editBtn.translatesAutoresizingMaskIntoConstraints = NO;
                    [vc.view addSubview:editBtn];
                    [NSLayoutConstraint activateConstraints:@[
                        [editBtn.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
                        [editBtn.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor constant:-80],
                        [editBtn.widthAnchor constraintEqualToConstant:220],
                        [editBtn.heightAnchor constraintEqualToConstant:44]
                    ]];
                    [editBtn addTarget:nil action:@selector(safeMAX_editDock:) forControlEvents:UIControlEventTouchUpInside];
                    // Bind action via runtime
                    class_addMethod([vc class], @selector(safeMAX_editDock:), (IMP)imp_implementationWithBlock(^(id _self, UIButton *sender) {
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Док"
                                                                                       message:@"Настройки нижнего бара"
                                                                                preferredStyle:UIAlertControllerStyleActionSheet];
                        [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Названия: %@", showLabels() ? @"вкл" : @"выкл"]
                                                                  style:UIAlertActionStyleDefault
                                                                handler:^(UIAlertAction *a) {
                            [[NSUserDefaults standardUserDefaults] setBool:!showLabels() forKey:kShowLabelsKey];
                            applyToAllTabBars();
                        }]];
                        [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Парящий док: %@", floatingDock() ? @"вкл" : @"выкл"]
                                                                  style:UIAlertActionStyleDefault
                                                                handler:^(UIAlertAction *a) {
                            [[NSUserDefaults standardUserDefaults] setBool:!floatingDock() forKey:kFloatingKey];
                            applyToAllTabBars();
                        }]];
                        [alert addAction:[UIAlertAction actionWithTitle:@"Закрыть" style:UIAlertActionStyleCancel handler:nil]];
                        [vc presentViewController:alert animated:YES completion:nil];
                    }), "v@:@");
                }
            }
        }
    }
}

__attribute__((constructor))
static void init(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        applyToAllTabBars();

        Class cls = [UITabBarController class];
        Method m = class_getInstanceMethod(cls, @selector(viewDidAppear:));
        if (m) {
            orig_viewDidAppear = (void *)method_getImplementation(m);
            method_setImplementation(m, (IMP)swizzled_viewDidAppear);
        }

        // Also swizzle UIViewController for broader coverage
        Class vcCls = [UIViewController class];
        Method vm = class_getInstanceMethod(vcCls, @selector(viewDidAppear:));
        if (vm && method_getImplementation(vm) != (IMP)swizzled_viewDidAppear) {
            // Only if not already swizzled via tab bar (simple)
        }
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ applyToAllTabBars(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ applyToAllTabBars(); });
}
