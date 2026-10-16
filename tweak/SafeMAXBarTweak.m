#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// SafeMAX bottom dock is OMUIKit.TabBar, not UITabBar.
// Never hide or fade existing subviews: that removes the icons.

static NSString *const kShowLabelsKey = @"SafeMAX_ShowLabels";
static NSString *const kFloatingKey = @"SafeMAX_FloatingDock";
static NSString *const kOrderKey = @"SafeMAX_TabOrder";

static const NSInteger kEntryTag = 0x5AF1;

static Class TabBarClass;
static Class SettingsClass;
static IMP orig_layout;
static IMP orig_vc_layout;
static IMP orig_appear;
static BOOL g_inStyle;
static BOOL g_inSettings;

static BOOL showLabels(void) {
    id obj = [[NSUserDefaults standardUserDefaults] objectForKey:kShowLabelsKey];
    return obj ? [obj boolValue] : YES;
}

static BOOL floatingDock(void) {
    id obj = [[NSUserDefaults standardUserDefaults] objectForKey:kFloatingKey];
    return obj ? [obj boolValue] : YES;
}

static NSArray<NSString *> *savedOrder(void) {
    id obj = [[NSUserDefaults standardUserDefaults] arrayForKey:kOrderKey];
    return [obj isKindOfClass:[NSArray class]] ? obj : nil;
}

static void saveOrder(NSArray<NSString *> *order) {
    [[NSUserDefaults standardUserDefaults] setObject:order forKey:kOrderKey];
}

static NSSet<NSString *> *knownTitles(void) {
    static NSSet *titles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        titles = [NSSet setWithArray:@[
            @"Контакты", @"Звонки", @"Чаты", @"Настройки",
            @"Contacts", @"Calls", @"Chats", @"Settings"
        ]];
    });
    return titles;
}

static NSArray<UIWindow *> *allWindows(void) {
    NSMutableArray *windows = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    }
    if (windows.count == 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [windows addObjectsFromArray:UIApplication.sharedApplication.windows];
#pragma clang diagnostic pop
    }
    return windows;
}

static void eachLabel(UIView *view, void (^block)(UILabel *label)) {
    if ([view isKindOfClass:[UILabel class]]) block((UILabel *)view);
    for (UIView *sub in view.subviews) eachLabel(sub, block);
}

static UIView *findKind(UIView *view, Class cls) {
    if (!view || !cls) return nil;
    if ([view isKindOfClass:cls]) return view;
    for (UIView *sub in view.subviews) {
        UIView *found = findKind(sub, cls);
        if (found) return found;
    }
    return nil;
}

static UITableView *findTable(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:[UITableView class]]) return (UITableView *)view;
    UITableView *best = nil;
    CGFloat bestArea = 0;
    for (UIView *sub in view.subviews) {
        UITableView *table = findTable(sub);
        if (!table) continue;
        CGFloat area = table.bounds.size.width * table.bounds.size.height;
        if (area >= bestArea) {
            best = table;
            bestArea = area;
        }
    }
    return best;
}

static NSInteger tabTitleCount(UIView *view) {
    __block NSInteger count = 0;
    eachLabel(view, ^(UILabel *label) {
        if ([knownTitles() containsObject:label.text]) count++;
    });
    return count;
}

static NSString *storedTitle(UIView *view) {
    id title = objc_getAssociatedObject(view, "sm_title");
    return [title isKindOfClass:[NSString class]] ? title : nil;
}

static void rememberTitle(UIView *view, NSString *title) {
    if (view && title.length) {
        objc_setAssociatedObject(view, "sm_title", title, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
}

static UILabel *primaryLabel(UIView *view) {
    __block UILabel *found = nil;
    eachLabel(view, ^(UILabel *label) {
        if (!found && label.text.length) found = label;
    });
    return found;
}

static NSString *titleOfItem(UIView *view) {
    UILabel *label = primaryLabel(view);
    if ([knownTitles() containsObject:label.text]) {
        rememberTitle(view, label.text);
        return label.text;
    }
    return storedTitle(view) ?: @"";
}

static UIView *tabItemForLabel(UILabel *label, UIView *bar) {
    UIView *view = label;
    while (view.superview && view.superview != bar &&
           view.superview.bounds.size.width < bar.bounds.size.width * 0.75) {
        view = view.superview;
    }
    return view == bar ? label : view;
}

static NSArray<UIView *> *tabItems(UIView *bar) {
    if (!bar) return @[];
    NSMutableArray *items = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    eachLabel(bar, ^(UILabel *label) {
        if (![knownTitles() containsObject:label.text] && ![knownTitles() containsObject:storedTitle(label)]) return;
        UIView *item = tabItemForLabel(label, bar);
        if (!item || item == bar || [seen containsObject:item]) return;
        [seen addObject:item];
        if ([knownTitles() containsObject:label.text]) rememberTitle(item, label.text);
        [items addObject:item];
    });
    [items sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat ax = CGRectGetMidX([a convertRect:a.bounds toView:bar]);
        CGFloat bx = CGRectGetMidX([b convertRect:b.bounds toView:bar]);
        if (ax < bx) return NSOrderedAscending;
        if (ax > bx) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return items;
}

static void applyLabels(UIView *bar) {
    BOOL on = showLabels();
    eachLabel(bar, ^(UILabel *label) {
        if (![knownTitles() containsObject:label.text] && !storedTitle(label)) return;
        if ([knownTitles() containsObject:label.text]) rememberTitle(label, label.text);
        label.hidden = !on;
    });
}

static void applyOrder(UIView *bar) {
    NSArray<NSString *> *order = savedOrder();
    if (order.count == 0) return;
    NSArray<UIView *> *items = tabItems(bar);
    if (items.count < 2) return;
    NSMutableArray<NSNumber *> *slots = [NSMutableArray array];
    for (UIView *item in items) [slots addObject:@(item.center.x)];
    NSMutableArray<UIView *> *arranged = [NSMutableArray array];
    NSMutableSet *used = [NSMutableSet set];
    for (NSString *title in order) {
        for (UIView *item in items) {
            if ([used containsObject:item]) continue;
            if ([titleOfItem(item) isEqualToString:title]) {
                [arranged addObject:item];
                [used addObject:item];
                break;
            }
        }
    }
    for (UIView *item in items) {
        if (![used containsObject:item]) [arranged addObject:item];
    }
    NSUInteger n = MIN(arranged.count, slots.count);
    for (NSUInteger i = 0; i < n; i++) {
        UIView *item = arranged[i];
        CGPoint center = item.center;
        center.x = slots[i].doubleValue;
        item.center = center;
    }
}

static BOOL isBottomBar(UIView *bar) {
    if (!bar.window || bar.bounds.size.width < 40 || bar.bounds.size.height < 36 || bar.bounds.size.height > 160) return NO;
    CGRect frame = [bar convertRect:bar.bounds toView:bar.window];
    if (CGRectGetMaxY(frame) < bar.window.bounds.size.height - 12) return NO;
    if (frame.size.width < bar.window.bounds.size.width * 0.7) return NO;
    return tabTitleCount(bar) >= 3;
}

static void styleTabBar(UIView *bar) {
    if (!isBottomBar(bar)) return;
    applyLabels(bar);
    applyOrder(bar);

    BOOL floating = floatingDock();
    bar.clipsToBounds = floating;
    bar.layer.cornerRadius = floating ? 28 : 0;
    bar.layer.borderWidth = floating ? 0.6 : 0;
    bar.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    // Scale instead of changing the frame so Auto Layout cannot hide the bar.
    bar.transform = floating ? CGAffineTransformMakeScale(0.90, 0.92) : CGAffineTransformIdentity;
}

static UIView *locateBar(void) {
    for (UIWindow *window in allWindows()) {
        if (TabBarClass) {
            UIView *bar = findKind(window, TabBarClass);
            if (isBottomBar(bar)) return bar;
        }
        NSMutableArray *stack = [NSMutableArray arrayWithObject:window];
        while (stack.count) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];
            if (isBottomBar(view)) return view;
            [stack addObjectsFromArray:view.subviews];
        }
    }
    return nil;
}

static void styleAllBars(void) {
    UIView *bar = locateBar();
    if (bar) styleTabBar(bar);
}

@interface SMDockEntry : UIControl
@property (nonatomic, weak) UIViewController *owner;
@end

@interface SMDockEditor : UITableViewController
@property (nonatomic, strong) NSMutableArray<NSString *> *titles;
@end

static void presentEditor(UIViewController *from);

@implementation SMDockEntry

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithRed:0.16 green:0.16 blue:0.18 alpha:1];
    self.layer.cornerRadius = 20;
    self.clipsToBounds = YES;
    [self addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"dock.rectangle"]];
    icon.tag = 1;
    icon.tintColor = [UIColor whiteColor];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:icon];

    UILabel *title = [[UILabel alloc] init];
    title.tag = 2;
    title.text = @"Нижний док";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:17];
    [self addSubview:title];

    UILabel *detail = [[UILabel alloc] init];
    detail.tag = 3;
    detail.text = @"Форма, подписи и порядок";
    detail.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    detail.font = [UIFont systemFontOfSize:13];
    [self addSubview:detail];

    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.tag = 4;
    chevron.tintColor = [UIColor colorWithWhite:1 alpha:0.35];
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:chevron];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self viewWithTag:1].frame = CGRectMake(16, 18, 24, 24);
    [self viewWithTag:4].frame = CGRectMake(self.bounds.size.width - 28, 23, 12, 16);
    [self viewWithTag:2].frame = CGRectMake(52, 10, self.bounds.size.width - 90, 22);
    [self viewWithTag:3].frame = CGRectMake(52, 32, self.bounds.size.width - 90, 18);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.65 : 1;
}

- (void)open {
    presentEditor(self.owner);
}

@end

@implementation SMDockEditor

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Нижний док";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.allowsSelectionDuringEditing = YES;
    self.tableView.editing = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    if (!self.titles) self.titles = [NSMutableArray array];
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
    styleAllBars();
}

- (void)switchChanged:(UISwitch *)sender {
    NSNumber *row = objc_getAssociatedObject(sender, "sm_row");
    if (row.integerValue == 0) {
        [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kShowLabelsKey];
    } else {
        [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kFloatingKey];
    }
    styleAllBars();
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 2 : self.titles.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Опции" : @"Порядок";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 1 ? @"Удерживайте полоски справа и перетаскивайте вкладки." : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"c"];
    cell.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *toggle = [cell.contentView viewWithTag:9];
    if (indexPath.section == 0) {
        cell.textLabel.text = indexPath.row == 0 ? @"Текст под иконками" : @"Парящий док";
        if (!toggle) {
            toggle = [[UISwitch alloc] init];
            toggle.tag = 9;
            toggle.translatesAutoresizingMaskIntoConstraints = NO;
            [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
            [cell.contentView addSubview:toggle];
            [NSLayoutConstraint activateConstraints:@[
                [toggle.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                [toggle.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8]
            ]];
        }
        toggle.hidden = NO;
        toggle.on = indexPath.row == 0 ? showLabels() : floatingDock();
        objc_setAssociatedObject(toggle, "sm_row", @(indexPath.row), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        cell.textLabel.text = self.titles[indexPath.row];
        toggle.hidden = YES;
    }
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1;
}

- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)source toProposedIndexPath:(NSIndexPath *)proposed {
    return proposed.section == 1 ? proposed : source;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)source toIndexPath:(NSIndexPath *)destination {
    if (source.section != 1 || destination.section != 1) return;
    NSString *title = self.titles[source.row];
    [self.titles removeObjectAtIndex:source.row];
    [self.titles insertObject:title atIndex:destination.row];
    saveOrder(self.titles);
    styleAllBars();
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

@end

static UIViewController *topController(void) {
    UIViewController *controller = nil;
    for (UIWindow *window in allWindows()) {
        if (window.isKeyWindow || !controller) controller = window.rootViewController;
    }
    while (controller.presentedViewController) controller = controller.presentedViewController;
    return controller;
}

static void presentEditor(UIViewController *from) {
    if (!from) from = topController();
    if (!from) return;
    NSMutableArray *titles = [NSMutableArray array];
    for (UIView *item in tabItems(locateBar())) {
        NSString *title = titleOfItem(item);
        if (title.length) [titles addObject:title];
    }
    if (titles.count == 0 && savedOrder().count) titles = [savedOrder() mutableCopy];
    SMDockEditor *editor = [[SMDockEditor alloc] init];
    editor.titles = titles;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [from presentViewController:nav animated:YES completion:nil];
}

static void installSettingsEntry(UIViewController *vc) {
    if (g_inSettings || (SettingsClass && ![vc isKindOfClass:SettingsClass])) return;
    g_inSettings = YES;

    UITableView *table = findTable(vc.view);
    if (!table || table.bounds.size.width < 20) {
        g_inSettings = NO;
        return;
    }

    // Drop the row if a previous layout stuck it over the profile cards.
    UIView *stray = [vc.view viewWithTag:kEntryTag];
    if (stray && stray != table.tableFooterView && ![stray isDescendantOfView:table.tableFooterView]) {
        [stray removeFromSuperview];
    }

    if (!objc_getAssociatedObject(table, "sm_inset")) {
        UIEdgeInsets inset = table.contentInset;
        inset.bottom += 88;
        table.contentInset = inset;
        table.verticalScrollIndicatorInsets = inset;
        objc_setAssociatedObject(table, "sm_inset", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (table.tableFooterView.tag != kEntryTag) {
        CGFloat width = table.bounds.size.width;
        UIView *existing = table.tableFooterView;
        CGFloat existingH = existing ? existing.bounds.size.height : 0;
        UIView *wrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, existingH + 108)];
        wrap.tag = kEntryTag;
        wrap.backgroundColor = [UIColor clearColor];
        if (existing) {
            existing.tag = 0;
            existing.frame = CGRectMake(0, 0, width, existingH);
            existing.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            [wrap addSubview:existing];
        }
        SMDockEntry *entry = [[SMDockEntry alloc] initWithFrame:CGRectMake(16, existingH + 16, width - 32, 62)];
        entry.owner = vc;
        entry.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [wrap addSubview:entry];
        table.tableFooterView = wrap;
    }

    g_inSettings = NO;
}

static BOOL isDockView(UIView *view) {
    if (TabBarClass) return [view isKindOfClass:TabBarClass];
    return isBottomBar(view);
}

static void swizzled_layout(id self, SEL _cmd) {
    ((void (*)(id, SEL))orig_layout)(self, _cmd);
    if (g_inStyle || ![self isKindOfClass:[UIView class]] || !isDockView((UIView *)self)) return;
    g_inStyle = YES;
    styleTabBar((UIView *)self);
    g_inStyle = NO;
}

static void swizzled_vc_layout(id self, SEL _cmd) {
    ((void (*)(id, SEL))orig_vc_layout)(self, _cmd);
    if (SettingsClass && [self isKindOfClass:SettingsClass]) installSettingsEntry((UIViewController *)self);
}

static void swizzled_appear(id self, SEL _cmd, BOOL animated) {
    ((void (*)(id, SEL, BOOL))orig_appear)(self, _cmd, animated);
    if (SettingsClass && [self isKindOfClass:SettingsClass]) installSettingsEntry((UIViewController *)self);
    styleAllBars();
}

static void resolveAndHook(void) {
    static BOOL hooked;
    TabBarClass = objc_getClass("_TtC7OMUIKit6TabBar");
    SettingsClass = objc_getClass("_TtC10SettingsUI22SettingsViewController");
    styleAllBars();
    if (hooked) return;
    hooked = YES;

    Method layout = class_getInstanceMethod([UIView class], @selector(layoutSubviews));
    orig_layout = method_getImplementation(layout);
    method_setImplementation(layout, (IMP)swizzled_layout);

    Method vcLayout = class_getInstanceMethod([UIViewController class], @selector(viewDidLayoutSubviews));
    orig_vc_layout = method_getImplementation(vcLayout);
    method_setImplementation(vcLayout, (IMP)swizzled_vc_layout);

    Method appear = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
    orig_appear = method_getImplementation(appear);
    method_setImplementation(appear, (IMP)swizzled_appear);
}

__attribute__((constructor))
static void safeMAXDockInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        resolveAndHook();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        resolveAndHook();
    });
}
