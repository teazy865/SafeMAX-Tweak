#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// SafeMAX does not use UITabBar. The bottom dock is OMUIKit.TabBar
// (_TtC7OMUIKit6TabBar). Settings is SettingsUI.SettingsViewController
// with custom cells, so UITableViewCell.textLabel never matches.

static NSString *const kShowLabelsKey = @"SafeMAX_ShowLabels";
static NSString *const kFloatingKey = @"SafeMAX_FloatingDock";
static NSString *const kOrderKey = @"SafeMAX_TabOrder";

static const NSInteger kPillTag = 0x5AFE;
static const NSInteger kHeaderWrapTag = 0x5AF2;
static const NSInteger kEntryTag = 0x5AF1;

static Class TabBarClass;
static Class SettingsClass;
static Class HeaderClass;
static IMP orig_layout;
static IMP orig_vc_layout;
static IMP orig_appear;
static BOOL g_inStyle;
static BOOL g_inSettings;
static BOOL g_logged;

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
    if (![obj isKindOfClass:[NSArray class]]) return nil;
    return obj;
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
        UITableView *t = findTable(sub);
        if (!t) continue;
        CGFloat area = t.bounds.size.width * t.bounds.size.height;
        if (area >= bestArea) {
            best = t;
            bestArea = area;
        }
    }
    return best;
}

static void eachLabel(UIView *view, void (^block)(UILabel *label)) {
    if ([view isKindOfClass:[UILabel class]]) block((UILabel *)view);
    for (UIView *sub in view.subviews) eachLabel(sub, block);
}

static NSString *storedTitle(UIView *view) {
    id t = objc_getAssociatedObject(view, "sm_title");
    return [t isKindOfClass:[NSString class]] ? t : nil;
}

static void rememberTitle(UIView *view, NSString *title) {
    if (title.length == 0 || view == nil) return;
    objc_setAssociatedObject(view, "sm_title", title, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static UILabel *primaryLabel(UIView *view) {
    __block UILabel *found = nil;
    eachLabel(view, ^(UILabel *label) {
        if (found) return;
        if (label.text.length > 0) found = label;
    });
    return found;
}

static NSString *titleOfItem(UIView *view) {
    NSString *stored = storedTitle(view);
    UILabel *label = primaryLabel(view);
    if (label.text.length && [knownTitles() containsObject:label.text]) {
        rememberTitle(view, label.text);
        return label.text;
    }
    return stored ?: label.text ?: @"";
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
    NSMutableArray *items = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    eachLabel(bar, ^(UILabel *label) {
        NSString *text = label.text;
        if (text.length == 0) text = storedTitle(label.superview);
        BOOL known = [knownTitles() containsObject:label.text] || [knownTitles() containsObject:storedTitle(label)];
        if (!known && label.text.length == 0) return;
        if (![knownTitles() containsObject:label.text] && ![knownTitles() containsObject:storedTitle(label.superview)]) {
            return;
        }
        UIView *item = tabItemForLabel(label, bar);
        if (!item || item == bar || [seen containsObject:item]) return;
        [seen addObject:item];
        rememberTitle(item, [knownTitles() containsObject:label.text] ? label.text : storedTitle(item));
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

static void applyLabels(UIView *bar) {
    BOOL labelsOn = showLabels();
    eachLabel(bar, ^(UILabel *label) {
        BOOL tabLabel = [knownTitles() containsObject:label.text] || storedTitle(label) != nil || [knownTitles() containsObject:storedTitle(label.superview)];
        if (!tabLabel) return;
        if (label.text.length && [knownTitles() containsObject:label.text]) {
            rememberTitle(label, label.text);
        }
        label.hidden = !labelsOn;
        label.alpha = labelsOn ? 1 : 0;
    });
}

static BOOL isBackdrop(UIView *sub, UIView *bar) {
    if (sub.tag == kPillTag || sub.tag == kEntryTag) return NO;
    NSString *name = NSStringFromClass(sub.class);
    if ([name containsString:@"Background"] || [name containsString:@"Effect"] ||
        [name containsString:@"Blur"] || [name containsString:@"Separator"] ||
        [name containsString:@"Backdrop"] || [name containsString:@"Shadow"]) {
        return YES;
    }
    BOOL hasContent = NO;
    eachLabel(sub, ^(UILabel *label) { hasContent = YES; });
    if (hasContent) return NO;
    if ([sub isKindOfClass:[UIImageView class]] && ((UIImageView *)sub).image) return NO;
    for (UIView *child in sub.subviews) {
        if ([child isKindOfClass:[UIImageView class]] && ((UIImageView *)child).image) return NO;
    }
    CGFloat w = bar.bounds.size.width;
    CGFloat h = bar.bounds.size.height;
    return sub.bounds.size.width > w * 0.85 && sub.bounds.size.height > h * 0.55;
}

static void setDimmed(UIView *view, BOOL dim) {
    NSNumber *flag = objc_getAssociatedObject(view, "sm_dim");
    if (dim) {
        if (!flag.boolValue) {
            objc_setAssociatedObject(view, "sm_alpha", @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, "sm_bg", view.backgroundColor ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, "sm_dim", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.alpha = 0;
    } else if (flag.boolValue) {
        NSNumber *alpha = objc_getAssociatedObject(view, "sm_alpha");
        id bg = objc_getAssociatedObject(view, "sm_bg");
        view.alpha = alpha ? alpha.doubleValue : 1;
        if (bg && bg != [NSNull null]) view.backgroundColor = bg;
        objc_setAssociatedObject(view, "sm_dim", @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void styleTabBar(UIView *bar) {
    if (![bar isKindOfClass:[UIView class]] || bar.bounds.size.width < 40 || bar.bounds.size.height < 20) return;
    if (bar.bounds.size.height > 220) return;

    BOOL floating = floatingDock();
    applyOrder(bar);
    applyLabels(bar);

    for (UIView *sub in bar.subviews) {
        if (sub.tag == kPillTag) continue;
        if (isBackdrop(sub, bar)) {
            setDimmed(sub, floating);
            continue;
        }
        if (!floating || sub.bounds.size.width < bar.bounds.size.width * 0.85) continue;
        if (!objc_getAssociatedObject(sub, "sm_fill")) {
            objc_setAssociatedObject(sub, "sm_fill", sub.backgroundColor ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        sub.backgroundColor = [UIColor clearColor];
        sub.opaque = NO;
    }
    if (!floating) {
        for (UIView *sub in bar.subviews) {
            id fill = objc_getAssociatedObject(sub, "sm_fill");
            if (!fill) continue;
            if (fill != [NSNull null]) sub.backgroundColor = fill;
            objc_setAssociatedObject(sub, "sm_fill", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    setDimmed(bar, NO);
    if (floating) {
        if (!objc_getAssociatedObject(bar, "sm_barbg")) {
            objc_setAssociatedObject(bar, "sm_barbg", bar.backgroundColor ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        bar.backgroundColor = [UIColor clearColor];
        bar.opaque = NO;
    } else {
        id bg = objc_getAssociatedObject(bar, "sm_barbg");
        if (bg && bg != [NSNull null]) bar.backgroundColor = bg;
    }

    UIView *host = bar.superview;
    if (host && host.bounds.size.height >= bar.bounds.size.height && host.bounds.size.height < 190) {
        if (floating) {
            if (!objc_getAssociatedObject(host, "sm_hostbg")) {
                objc_setAssociatedObject(host, "sm_hostbg", host.backgroundColor ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            host.backgroundColor = [UIColor clearColor];
            host.opaque = NO;
        } else {
            id bg = objc_getAssociatedObject(host, "sm_hostbg");
            if (bg && bg != [NSNull null]) host.backgroundColor = bg;
        }
    }

    UIView *pill = [bar viewWithTag:kPillTag];
    if (!pill) {
        pill = [[UIView alloc] initWithFrame:CGRectZero];
        pill.tag = kPillTag;
        pill.userInteractionEnabled = NO;
        pill.backgroundColor = [UIColor colorWithRed:0.17 green:0.17 blue:0.19 alpha:0.96];
        pill.layer.cornerRadius = 28;
        pill.layer.borderWidth = 0.5;
        pill.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
        pill.layer.shadowColor = [UIColor blackColor].CGColor;
        pill.layer.shadowOpacity = 0.35;
        pill.layer.shadowRadius = 12;
        pill.layer.shadowOffset = CGSizeMake(0, 6);
        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
        blur.tag = 77;
        blur.userInteractionEnabled = NO;
        blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        blur.layer.cornerRadius = 28;
        blur.clipsToBounds = YES;
        [pill addSubview:blur];
        [bar insertSubview:pill atIndex:0];
    }
    [bar sendSubviewToBack:pill];

    CGFloat side = floating ? 14.0 : 0;
    CGFloat bottomGap = 0;
    if (floating) bottomGap = bar.bounds.size.height > 72 ? 14.0 : 5.0;
    CGFloat topGap = floating ? 3.0 : 0;
    CGRect frame = CGRectMake(side, topGap, MAX(0, bar.bounds.size.width - side * 2), MAX(0, bar.bounds.size.height - topGap - bottomGap));
    pill.frame = frame;
    pill.layer.cornerRadius = floating ? MIN(28, frame.size.height / 2.0) : 0;
    UIView *blur = [pill viewWithTag:77];
    blur.frame = pill.bounds;
    blur.layer.cornerRadius = pill.layer.cornerRadius;
    pill.hidden = !floating;

    if (!g_logged) {
        g_logged = YES;
        NSLog(@"[SafeMAXDock] styled %@ bounds %@", NSStringFromClass(bar.class), NSStringFromCGRect(bar.bounds));
    }
}

static UIView *locateBar(void) {
    for (UIWindow *window in allWindows()) {
        if (TabBarClass) {
            UIView *bar = findKind(window, TabBarClass);
            if (bar) return bar;
        }
        UIView *flagged = nil;
        // Walk a shallow search via the known flag set during layout.
        NSMutableArray *stack = [NSMutableArray arrayWithObject:window];
        while (stack.count) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];
            if (objc_getAssociatedObject(view, "sm_isDock")) flagged = view;
            [stack addObjectsFromArray:view.subviews];
        }
        if (flagged) return flagged;
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
    self.backgroundColor = [UIColor colorWithRed:0.17 green:0.17 blue:0.19 alpha:1];
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
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
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
    UIView *icon = [self viewWithTag:1];
    UIView *title = [self viewWithTag:2];
    UIView *detail = [self viewWithTag:3];
    UIView *chevron = [self viewWithTag:4];
    icon.frame = CGRectMake(16, 18, 24, 24);
    chevron.frame = CGRectMake(self.bounds.size.width - 28, 23, 12, 16);
    title.frame = CGRectMake(52, 10, self.bounds.size.width - 90, 22);
    detail.frame = CGRectMake(52, 32, self.bounds.size.width - 90, 18);
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
    self.tableView.editing = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    if (!self.titles) self.titles = [NSMutableArray array];
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
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
    if (section == 1) return @"Удерживайте полоски справа и перетаскивайте вкладки.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"c"];
    cell.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1];
    cell.textLabel.textColor = [UIColor whiteColor];
    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Текст под иконками";
            cell.accessoryType = showLabels() ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        } else {
            cell.textLabel.text = @"Парящий док";
            cell.accessoryType = floatingDock() ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        }
        cell.showsReorderControl = NO;
    } else {
        cell.textLabel.text = self.titles[indexPath.row];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.showsReorderControl = YES;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 0) return;
    if (indexPath.row == 0) {
        [[NSUserDefaults standardUserDefaults] setBool:!showLabels() forKey:kShowLabelsKey];
    } else {
        [[NSUserDefaults standardUserDefaults] setBool:!floatingDock() forKey:kFloatingKey];
    }
    [tableView reloadData];
    styleAllBars();
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1;
}

- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)source toProposedIndexPath:(NSIndexPath *)proposed {
    if (proposed.section != 1) return source;
    return proposed;
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
    UIViewController *vc = nil;
    for (UIWindow *window in allWindows()) {
        if (window.isKeyWindow || !vc) vc = window.rootViewController;
    }
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void presentEditor(UIViewController *from) {
    if (!from) from = topController();
    if (!from) return;
    NSMutableArray *titles = [NSMutableArray array];
    UIView *bar = locateBar();
    for (UIView *item in tabItems(bar)) {
        NSString *title = titleOfItem(item);
        if (title.length) [titles addObject:title];
    }
    if (titles.count == 0) {
        NSArray *saved = savedOrder();
        if (saved.count) titles = [saved mutableCopy];
    }
    SMDockEditor *editor = [[SMDockEditor alloc] init];
    editor.titles = titles;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [from presentViewController:nav animated:YES completion:nil];
}

static void installSettingsEntry(UIViewController *vc) {
    if (g_inSettings) return;
    if (SettingsClass && ![vc isKindOfClass:SettingsClass]) return;
    g_inSettings = YES;

    UITableView *table = findTable(vc.view);
    if (table && table.bounds.size.width > 20) {
        UIView *header = table.tableHeaderView;
        if (header.tag != kHeaderWrapTag && ![header viewWithTag:kEntryTag]) {
            CGFloat width = table.bounds.size.width;
            CGFloat headerH = header.bounds.size.height;
            if (!header || headerH > 1 || table.contentOffset.y > -1000) {
                UIView *wrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, headerH + 78)];
                wrap.tag = kHeaderWrapTag;
                wrap.backgroundColor = [UIColor clearColor];
                if (header) {
                    header.translatesAutoresizingMaskIntoConstraints = YES;
                    header.frame = CGRectMake(0, 0, width, headerH);
                    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;
                    [wrap addSubview:header];
                }
                SMDockEntry *entry = [[SMDockEntry alloc] initWithFrame:CGRectMake(16, headerH + 8, width - 32, 62)];
                entry.tag = kEntryTag;
                entry.owner = vc;
                entry.autoresizingMask = UIViewAutoresizingFlexibleWidth;
                [wrap addSubview:entry];
                table.tableHeaderView = wrap;
            }
        }
    } else if (![vc.view viewWithTag:kEntryTag]) {
        SMDockEntry *entry = [[SMDockEntry alloc] initWithFrame:CGRectZero];
        entry.tag = kEntryTag;
        entry.owner = vc;
        entry.translatesAutoresizingMaskIntoConstraints = NO;
        [vc.view addSubview:entry];
        [NSLayoutConstraint activateConstraints:@[
            [entry.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor constant:16],
            [entry.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor constant:-16],
            [entry.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:8],
            [entry.heightAnchor constraintEqualToConstant:62]
        ]];
    }

    g_inSettings = NO;
}

static void markDock(UIView *view) {
    if (!view) return;
    objc_setAssociatedObject(view, "sm_isDock", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL isDockView(UIView *view) {
    if (TabBarClass && [view isKindOfClass:TabBarClass]) return YES;
    return objc_getAssociatedObject(view, "sm_isDock") != nil;
}

static void swizzled_layout(id self, SEL _cmd) {
    ((void (*)(id, SEL))orig_layout)(self, _cmd);
    if (g_inStyle) return;
    if (![self isKindOfClass:[UIView class]]) return;
    if (!isDockView(self)) return;
    g_inStyle = YES;
    styleTabBar((UIView *)self);
    g_inStyle = NO;
}

static void swizzled_vc_layout(id self, SEL _cmd) {
    ((void (*)(id, SEL))orig_vc_layout)(self, _cmd);
    if (SettingsClass && [self isKindOfClass:SettingsClass]) {
        installSettingsEntry((UIViewController *)self);
    }
}

static void swizzled_appear(id self, SEL _cmd, BOOL animated) {
    ((void (*)(id, SEL, BOOL))orig_appear)(self, _cmd, animated);
    if (TabBarClass && [self isKindOfClass:[UIViewController class]]) {
        UIView *bar = findKind(((UIViewController *)self).view, TabBarClass);
        if (!bar && [self isKindOfClass:TabBarClass]) {
            // TabBarController's view hosts the bar one level down; search window.
        }
        if (bar) {
            markDock(bar);
            styleTabBar(bar);
        }
    }
    if (SettingsClass && [self isKindOfClass:SettingsClass]) {
        installSettingsEntry((UIViewController *)self);
    }
}

static UIView *discoverByTitles(void) {
    for (UIWindow *window in allWindows()) {
        NSMutableArray<UILabel *> *labels = [NSMutableArray array];
        NSMutableArray *stack = [NSMutableArray arrayWithObject:window];
        while (stack.count) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];
            if ([view isKindOfClass:[UILabel class]]) {
                UILabel *label = (UILabel *)view;
                if ([knownTitles() containsObject:label.text]) {
                    CGRect frame = [label convertRect:label.bounds toView:window];
                    if (CGRectGetMinY(frame) > window.bounds.size.height * 0.72) {
                        [labels addObject:label];
                    }
                }
            }
            [stack addObjectsFromArray:view.subviews];
        }
        if (labels.count < 3) continue;
        UIView *view = labels.firstObject;
        while (view.superview && view.superview != window) {
            NSUInteger hits = 0;
            for (UILabel *label in labels) {
                if ([label isDescendantOfView:view]) hits++;
            }
            BOOL shortBar = view.bounds.size.height > 36 && view.bounds.size.height < 200 &&
                            view.bounds.size.width > window.bounds.size.width * 0.7;
            if (hits >= 3 && shortBar) return view;
            view = view.superview;
        }
    }
    return nil;
}

static void resolveAndHook(void) {
    static BOOL hooked;
    TabBarClass = objc_getClass("_TtC7OMUIKit6TabBar");
    SettingsClass = objc_getClass("_TtC10SettingsUI22SettingsViewController");
    HeaderClass = objc_getClass("_TtC10SettingsUI18SettingsHeaderView");
    (void)HeaderClass;
    NSLog(@"[SafeMAXDock] classes tab=%@ settings=%@", TabBarClass, SettingsClass);

    UIView *discovered = discoverByTitles();
    if (discovered) {
        markDock(discovered);
        styleTabBar(discovered);
    }
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        resolveAndHook();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        resolveAndHook();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        resolveAndHook();
    });
}
