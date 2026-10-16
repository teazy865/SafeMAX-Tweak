#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Runtime tweak for SafeMAX bottom tab bar
// - Compact floating dock
// - Labels toggle
// - Settings item to reorder icons + toggle text

static NSString *const kShowLabelsKey = @"SafeMAX_ShowLabels";
static NSString *const kFloatingKey = @"SafeMAX_FloatingDock";
static NSString *const kOrderKey = @"SafeMAX_TabOrder";

static BOOL showLabels(void) {
    id obj = [[NSUserDefaults standardUserDefaults] objectForKey:kShowLabelsKey];
    return obj ? [obj boolValue] : YES;
}

static BOOL floatingDock(void) {
    id obj = [[NSUserDefaults standardUserDefaults] objectForKey:kFloatingKey];
    return obj ? [obj boolValue] : YES;
}

static NSArray<NSNumber *> *savedOrder(void) {
    return [[NSUserDefaults standardUserDefaults] arrayForKey:kOrderKey];
}

static void saveOrder(NSArray<NSNumber *> *order) {
    [[NSUserDefaults standardUserDefaults] setObject:order forKey:kOrderKey];
}

static void styleTabBar(UITabBar *tabBar) {
    if (!tabBar) return;

    BOOL labels = showLabels();
    BOOL floating = floatingDock();

    // Apply saved order if any
    NSArray *order = savedOrder();
    if (order.count == tabBar.items.count) {
        NSMutableArray *newItems = [NSMutableArray array];
        for (NSNumber *idx in order) {
            NSUInteger i = idx.unsignedIntegerValue;
            if (i < tabBar.items.count) [newItems addObject:tabBar.items[i]];
        }
        if (newItems.count == tabBar.items.count) {
            tabBar.items = newItems;
        }
    }

    for (UITabBarItem *item in tabBar.items) {
        if (!labels) {
            item.title = nil;
            item.imageInsets = UIEdgeInsetsMake(4, 0, -4, 0);
        } else {
            item.imageInsets = UIEdgeInsetsZero;
        }
    }

    UITabBarAppearance *appearance = [[UITabBarAppearance alloc] init];
    [appearance configureWithTransparentBackground];
    appearance.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    appearance.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.6];

    appearance.stackedLayoutAppearance.selected.iconColor = [UIColor whiteColor];
    appearance.stackedLayoutAppearance.normal.iconColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    appearance.stackedLayoutAppearance.selected.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor whiteColor], NSFontAttributeName: [UIFont systemFontOfSize:10]};
    appearance.stackedLayoutAppearance.normal.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.55], NSFontAttributeName: [UIFont systemFontOfSize:10]};

    tabBar.standardAppearance = appearance;
    if (@available(iOS 15.0, *)) {
        tabBar.scrollEdgeAppearance = appearance;
    }

    tabBar.layer.cornerRadius = floating ? 22 : 0;
    tabBar.layer.masksToBounds = floating;
    tabBar.layer.borderWidth = floating ? 0.5 : 0;
    tabBar.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    tabBar.layer.shadowOpacity = floating ? 0.3 : 0;
    tabBar.layer.shadowRadius = 8;
    tabBar.layer.shadowOffset = CGSizeMake(0, 2);

    if (floating) {
        CGRect frame = tabBar.frame;
        CGFloat inset = 16;
        frame.origin.x = inset;
        frame.size.width = tabBar.superview.bounds.size.width - inset * 2;
        frame.origin.y = tabBar.superview.bounds.size.height - frame.size.height - 12;
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

// Simple editor VC
@interface SafeMAXDockEditor : UITableViewController
@property (nonatomic, strong) NSMutableArray<UITabBarItem *> *items;
@property (nonatomic, assign) UITabBar *tabBar; // assign instead of weak for MRC
@end

@implementation SafeMAXDockEditor

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Редактировать док";
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
    applyToAllTabBars();
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 2 : self.items.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Опции" : @"Порядок иконок (перетаскивайте)";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"cell"];
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Текст под иконками";
            cell.accessoryType = showLabels() ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        } else {
            cell.textLabel.text = @"Парящий док";
            cell.accessoryType = floatingDock() ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        }
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        UITabBarItem *item = self.items[indexPath.row];
        cell.textLabel.text = item.title ?: @"Без названия";
        cell.imageView.image = item.image;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.showsReorderControl = YES;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            [[NSUserDefaults standardUserDefaults] setBool:!showLabels() forKey:kShowLabelsKey];
        } else {
            [[NSUserDefaults standardUserDefaults] setBool:!floatingDock() forKey:kFloatingKey];
        }
        [tableView reloadData];
        applyToAllTabBars();
    }
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (sourceIndexPath.section != 1 || destinationIndexPath.section != 1) return;
    UITabBarItem *item = self.items[sourceIndexPath.row];
    [self.items removeObjectAtIndex:sourceIndexPath.row];
    [self.items insertObject:item atIndex:destinationIndexPath.row];

    NSMutableArray *order = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.items.count; i++) [order addObject:@(i)];
    saveOrder(order);

    if (self.tabBar) {
        self.tabBar.items = [self.items copy];
    }
    applyToAllTabBars();
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

@end

static void presentEditor(UIViewController *from) {
    UITabBar *tabBar = nil;
    UIViewController *root = UIApplication.sharedApplication.windows.firstObject.rootViewController;
    if ([root isKindOfClass:[UITabBarController class]]) {
        tabBar = ((UITabBarController *)root).tabBar;
    }
    if (!tabBar) return;

    SafeMAXDockEditor *editor = [[SafeMAXDockEditor alloc] init];
    editor.items = [tabBar.items mutableCopy];
    editor.tabBar = tabBar;
    editor.tableView.editing = YES;

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [from presentViewController:nav animated:YES completion:nil];
}

// Settings injection
static void (*orig_viewDidAppear)(id, SEL, BOOL);
static void swizzled_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_viewDidAppear(self, _cmd, animated);

    if ([self isKindOfClass:[UITabBarController class]]) {
        styleTabBar(((UITabBarController *)self).tabBar);
    }

    if (![self isKindOfClass:[UIViewController class]]) return;
    UIViewController *vc = (UIViewController *)self;

    for (UIView *sub in vc.view.subviews) {
        if (![sub isKindOfClass:[UITableView class]]) continue;
        UITableView *tv = (UITableView *)sub;

        BOOL isSettings = NO;
        for (UITableViewCell *cell in tv.visibleCells) {
            NSString *t = cell.textLabel.text;
            if ([t containsString:@"Оформление"] || [t containsString:@"Язык приложения"] || [t containsString:@"Помощь"] || [t containsString:@"О приложении"]) {
                isSettings = YES;
                break;
            }
        }
        if (!isSettings || objc_getAssociatedObject(tv, "safeMAXRowInjected")) continue;

        objc_setAssociatedObject(tv, "safeMAXRowInjected", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        [btn setTitle:@"Редактировать док" forState:UIControlStateNormal];
        btn.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.95];
        btn.layer.cornerRadius = 12;
        btn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        [vc.view addSubview:btn];
        [NSLayoutConstraint activateConstraints:@[
            [btn.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:20],
            [btn.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-20],
            [btn.bottomAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor constant:-70],
            [btn.heightAnchor constraintEqualToConstant:48]
        ]];

        class_addMethod([vc class], @selector(safeMAX_openEditor:), (IMP)imp_implementationWithBlock(^(id _self, id sender) {
            presentEditor((UIViewController *)_self);
        }), "v@:@");
        [btn addTarget:vc action:@selector(safeMAX_openEditor:) forControlEvents:UIControlEventTouchUpInside];
    }
}

__attribute__((constructor))
static void init(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        applyToAllTabBars();

        Class cls = [UIViewController class];
        Method m = class_getInstanceMethod(cls, @selector(viewDidAppear:));
        if (m) {
            orig_viewDidAppear = (void *)method_getImplementation(m);
            method_setImplementation(m, (IMP)swizzled_viewDidAppear);
        }
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ applyToAllTabBars(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ applyToAllTabBars(); });
}
