#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <QuartzCore/QuartzCore.h>

// SafeMAX bottom dock is OMUIKit.TabBar, not UITabBar.
// Never hide or fade existing subviews: that removes the icons.

static NSString *const kShowLabelsKey = @"SafeMAX_ShowLabels";
static NSString *const kFloatingKey = @"SafeMAX_FloatingDock";
static NSString *const kOrderKey = @"SafeMAX_TabOrder";
static NSString *const kGhostKey = @"SafeMAX_GhostMode";
static NSString *const kAntiReadKey = @"SafeMAX_AntiRead";
static NSString *const kKeepDeletedKey = @"SafeMAX_KeepDeleted";
static NSString *const kKeepEditsKey = @"SafeMAX_KeepEdits";

static const NSInteger kEntryTag = 0x5AF1;
static const NSInteger kPillTag = 0x5AF3;
static const NSInteger kGhostTag = 0x5AF5;

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

static BOOL ghostMode(void) {
    id obj = [[NSUserDefaults standardUserDefaults] objectForKey:kGhostKey];
    return obj ? [obj boolValue] : NO;
}

static BOOL antiRead(void) {
    id obj = [[NSUserDefaults standardUserDefaults] objectForKey:kAntiReadKey];
    return obj ? [obj boolValue] : NO;
}

static BOOL keepDeleted(void) {
    id obj = [[NSUserDefaults standardUserDefaults] objectForKey:kKeepDeletedKey];
    return obj ? [obj boolValue] : NO;
}

static BOOL keepEdits(void) {
    id obj = [[NSUserDefaults standardUserDefaults] objectForKey:kKeepEditsKey];
    return obj ? [obj boolValue] : NO;
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

static UIImageView *largestIcon(UIView *item) {
    __block UIImageView *best = nil;
    __block CGFloat bestArea = 0;
    __block void (^walk)(UIView *);
    walk = ^(UIView *view) {
        if (!view || view.tag == kPillTag || view.hidden) return;
        if ([view isKindOfClass:[UIImageView class]] && ((UIImageView *)view).image) {
            CGFloat area = view.bounds.size.width * view.bounds.size.height;
            if (area > bestArea) {
                best = (UIImageView *)view;
                bestArea = area;
            }
        }
        for (UIView *sub in view.subviews) walk(sub);
    };
    walk(item);
    return best;
}

static void alignIcons(UIView *bar) {
    BOOL labelsOn = showLabels();
    for (UIView *item in tabItems(bar)) {
        UIImageView *icon = largestIcon(item);
        if (!icon.superview) continue;
        if (labelsOn) {
            NSValue *saved = objc_getAssociatedObject(icon, "sm_iconCenter");
            if (saved) {
                icon.center = saved.CGPointValue;
                objc_setAssociatedObject(icon, "sm_iconCenter", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            continue;
        }
        if (!objc_getAssociatedObject(icon, "sm_iconCenter")) {
            objc_setAssociatedObject(icon, "sm_iconCenter", [NSValue valueWithCGPoint:icon.center], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        CGPoint mid = [item convertPoint:CGPointMake(CGRectGetMidX(item.bounds), CGRectGetMidY(item.bounds)) toView:icon.superview];
        icon.center = mid;
    }
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

static BOOL viewHasChrome(UIView *view) {
    if (!view || view.tag == kPillTag) return NO;
    if ([view isKindOfClass:[UILabel class]] && ((UILabel *)view).text.length > 0) return YES;
    if ([view isKindOfClass:[UIImageView class]] && ((UIImageView *)view).image) return YES;
    if ([view isKindOfClass:[UIControl class]]) return YES;
    for (UIView *sub in view.subviews) {
        if (viewHasChrome(sub)) return YES;
    }
    return NO;
}

static void rememberOnce(UIView *view, const void *key, id value) {
    if (!objc_getAssociatedObject(view, key)) {
        objc_setAssociatedObject(view, key, value ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void setBackdropHidden(UIView *view, BOOL hidden) {
    if (hidden) {
        rememberOnce(view, "sm_alpha", @(view.alpha));
        view.alpha = 0;
    } else if (objc_getAssociatedObject(view, "sm_alpha")) {
        view.alpha = [objc_getAssociatedObject(view, "sm_alpha") doubleValue];
    }
}

static void clearFill(UIView *view, BOOL clear) {
    if (clear) {
        rememberOnce(view, "sm_bg", view.backgroundColor ?: [NSNull null]);
        view.backgroundColor = [UIColor clearColor];
        view.opaque = NO;
    } else {
        id bg = objc_getAssociatedObject(view, "sm_bg");
        if (bg && bg != [NSNull null]) view.backgroundColor = bg;
    }
}

static void clearEffect(UIView *view, BOOL clear) {
    if (![view isKindOfClass:[UIVisualEffectView class]]) return;
    UIVisualEffectView *effectView = (UIVisualEffectView *)view;
    if (clear) {
        rememberOnce(effectView, "sm_fx", effectView.effect ?: [NSNull null]);
        effectView.effect = nil;
        effectView.backgroundColor = [UIColor clearColor];
    } else {
        id effect = objc_getAssociatedObject(effectView, "sm_fx");
        if (effect && effect != [NSNull null]) effectView.effect = effect;
    }
}

static BOOL isFullPlate(UIView *sub, UIView *host) {
    if (sub.bounds.size.width < host.bounds.size.width * 0.75) return NO;
    if (sub.bounds.size.height < host.bounds.size.height * 0.45) return NO;
    if ([sub isKindOfClass:[UIImageView class]] || [sub isKindOfClass:[UILabel class]] || [sub isKindOfClass:[UIControl class]]) return NO;
    return !viewHasChrome(sub);
}

static void stripBackdrops(UIView *view, BOOL floating) {
    for (UIView *sub in view.subviews) {
        if (sub.tag == kPillTag) continue;
        if (viewHasChrome(sub)) {
            // Never fade a view that holds an icon. The tab-switch animation
            // swaps those views, and forcing alpha to 0 blanks the icon.
            setBackdropHidden(sub, NO);
            BOOL plate = sub.bounds.size.width > view.bounds.size.width * 0.8 &&
                         sub.bounds.size.height > view.bounds.size.height * 0.7;
            if (plate) {
                clearFill(sub, floating);
                clearEffect(sub, floating);
            }
            stripBackdrops(sub, floating);
        } else if (floating && isFullPlate(sub, view)) {
            setBackdropHidden(sub, YES);
        } else {
            setBackdropHidden(sub, NO);
        }
    }
}

static CGRect chromeBounds(UIView *bar) {
    __block CGRect box = CGRectNull;
    __block void (^recurse)(UIView *);
    recurse = ^(UIView *view) {
        if (!view || view.tag == kPillTag || view.hidden || view.alpha < 0.05) return;
        BOOL glyph = ([view isKindOfClass:[UILabel class]] && ((UILabel *)view).text.length > 0) ||
                     ([view isKindOfClass:[UIImageView class]] && ((UIImageView *)view).image != nil);
        if (glyph) {
            CGRect frame = [view convertRect:view.bounds toView:bar];
            if (frame.size.width > 1 && frame.size.height > 1) {
                box = CGRectIsNull(box) ? frame : CGRectUnion(box, frame);
            }
        }
        for (UIView *child in view.subviews) recurse(child);
    };
    recurse(bar);
    return box;
}

static UIVisualEffect *makeGlass(void) {
    Class cls = NSClassFromString(@"UIGlassEffect");
    SEL factory = @selector(effectWithStyle:);
    if (cls && [cls respondsToSelector:factory]) {
        // UIGlassEffectStyleRegular. A plain -init paints a solid black or white fill.
        id effect = ((id (*)(Class, SEL, NSInteger))objc_msgSend)(cls, factory, 0);
        if ([effect respondsToSelector:@selector(setInteractive:)]) {
            [effect setInteractive:YES];
        }
        if (effect) return effect;
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
}

static void styleTabBar(UIView *bar) {
    if (!isBottomBar(bar)) return;
    applyLabels(bar);
    alignIcons(bar);
    applyOrder(bar);

    BOOL floating = floatingDock();
    bar.transform = CGAffineTransformIdentity;
    bar.clipsToBounds = NO;
    bar.layer.cornerRadius = 0;
    bar.layer.borderWidth = 0;
    if (floating) {
        rememberOnce(bar, "sm_barbg", bar.backgroundColor ?: [NSNull null]);
        bar.backgroundColor = [UIColor clearColor];
        bar.opaque = NO;
        bar.layer.backgroundColor = UIColor.clearColor.CGColor;
    } else {
        id bg = objc_getAssociatedObject(bar, "sm_barbg");
        if (bg && bg != [NSNull null]) bar.backgroundColor = bg;
    }
    stripBackdrops(bar, floating);

    UIView *pill = [bar viewWithTag:kPillTag];
    if (!floating) {
        [pill removeFromSuperview];
        return;
    }

    CGRect glyphs = chromeBounds(bar);
    if (CGRectIsNull(glyphs)) return;
    CGFloat side = 18;
    CGFloat padY = 9;
    CGFloat height = MAX(56, CGRectGetHeight(glyphs) + padY * 2);
    CGFloat y = CGRectGetMidY(glyphs) - height / 2.0;
    if (y < 2) y = 2;
    if (y + height > bar.bounds.size.height - 2) y = MAX(2, bar.bounds.size.height - 2 - height);
    CGRect frame = CGRectMake(side, y, bar.bounds.size.width - side * 2, height);

    if (!pill) {
        pill = [[UIView alloc] initWithFrame:frame];
        pill.tag = kPillTag;
        pill.userInteractionEnabled = NO;
        pill.backgroundColor = [UIColor clearColor];
        pill.layer.shadowColor = [UIColor blackColor].CGColor;
        pill.layer.shadowOpacity = 0.28;
        pill.layer.shadowRadius = 18;
        pill.layer.shadowOffset = CGSizeMake(0, 8);
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:nil];
        glass.tag = 7;
        glass.userInteractionEnabled = NO;
        glass.backgroundColor = [UIColor clearColor];
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [pill addSubview:glass];
        [bar insertSubview:pill atIndex:0];
    }
    pill.frame = frame;
    pill.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:pill.bounds cornerRadius:height / 2.0].CGPath;
    UIVisualEffectView *glass = (UIVisualEffectView *)[pill viewWithTag:7];
    glass.frame = pill.bounds;
    if (!objc_getAssociatedObject(glass, "sm_glass")) {
        objc_setAssociatedObject(glass, "sm_glass", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        glass.backgroundColor = [UIColor clearColor];
        glass.clipsToBounds = NO;
        glass.layer.cornerRadius = 0;
        glass.effect = makeGlass();
    }
    glass.layer.cornerRadius = height / 2.0;
    glass.layer.cornerCurve = kCACornerCurveCircular;
    [bar sendSubviewToBack:pill];
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
static void presentGhost(UIViewController *from);

@implementation SMDockEntry

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1];
    self.layer.cornerRadius = 22;
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

    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIFontWeightSemibold]]];
    chevron.tag = 4;
    chevron.tintColor = [UIColor colorWithWhite:1 alpha:0.28];
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:chevron];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UIColor *foreground = [UIColor labelColor];
    self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    ((UIImageView *)[self viewWithTag:1]).tintColor = foreground;
    UILabel *title = (UILabel *)[self viewWithTag:2];
    title.textColor = foreground;
    ((UIImageView *)[self viewWithTag:4]).tintColor = [UIColor tertiaryLabelColor];
    [self viewWithTag:1].frame = CGRectMake(16, (self.bounds.size.height - 24) / 2.0, 24, 24);
    [self viewWithTag:4].frame = CGRectMake(self.bounds.size.width - 28, (self.bounds.size.height - 14) / 2.0, 12, 14);
    title.frame = CGRectMake(56, 0, self.bounds.size.width - 96, self.bounds.size.height);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.65 : 1;
}

- (void)open {
    if (self.tag == kGhostTag) presentGhost(self.owner);
    else presentEditor(self.owner);
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
        NSString *title = indexPath.row == 0 ? @"Текст под иконками" : @"Парящий док";
        BOOL on = indexPath.row == 0 ? showLabels() : floatingDock();
        cell.textLabel.text = title;
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
        toggle.on = on;
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

@interface SMGhostEditor : UITableViewController
@end

@implementation SMGhostEditor

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Невидимка";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)switchChanged:(UISwitch *)sender {
    NSNumber *row = objc_getAssociatedObject(sender, "sm_row");
    NSString *key = kGhostKey;
    switch (row.integerValue) {
        case 1: key = kAntiReadKey; break;
        case 2: key = kKeepDeletedKey; break;
        case 3: key = kKeepEditsKey; break;
        default: break;
    }
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:key];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 4; }

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath { return 60; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"g"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"g"];
    cell.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:0.55];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    BOOL on = NO;
    switch (indexPath.row) {
        case 0:
            cell.textLabel.text = @"Скрыть онлайн";
            cell.detailTextLabel.text = @"Вас не видно в сети";
            on = ghostMode();
            break;
        case 1:
            cell.textLabel.text = @"Нечиталка";
            cell.detailTextLabel.text = @"Сообщения не отмечаются прочитанными";
            on = antiRead();
            break;
        case 2:
            cell.textLabel.text = @"Удалённые сообщения";
            cell.detailTextLabel.text = @"Текст остаётся, даже если его удалили";
            on = keepDeleted();
            break;
        default:
            cell.textLabel.text = @"История правок";
            cell.detailTextLabel.text = @"Старый текст остаётся под новым";
            on = keepEdits();
            break;
    }
    UISwitch *toggle = [[UISwitch alloc] init];
    objc_setAssociatedObject(toggle, "sm_row", @(indexPath.row), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    toggle.on = on;
    cell.accessoryView = toggle;
    return cell;
}

@end

static void presentGhost(UIViewController *from) {
    if (!from) from = topController();
    if (!from) return;
    SMGhostEditor *editor = [[SMGhostEditor alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [from presentViewController:nav animated:YES completion:nil];
}

static UIScrollView *findMainScroll(UIView *view) {
    UIScrollView *best = nil;
    CGFloat bestHeight = 0;
    if ([view isKindOfClass:[UIScrollView class]] && view.bounds.size.height > bestHeight) {
        best = (UIScrollView *)view;
        bestHeight = view.bounds.size.height;
    }
    for (UIView *sub in view.subviews) {
        UIScrollView *found = findMainScroll(sub);
        if (found && found.bounds.size.height > bestHeight) {
            best = found;
            bestHeight = found.bounds.size.height;
        }
    }
    return best;
}

static void installSettingsEntry(UIViewController *vc) {
    if (g_inSettings || (SettingsClass && ![vc isKindOfClass:SettingsClass])) return;
    g_inSettings = YES;

    UIScrollView *scroll = findMainScroll(vc.view);
    if (!scroll || scroll.bounds.size.width < 40 || scroll.contentSize.height < 80) {
        g_inSettings = NO;
        return;
    }

    SMDockEntry *entry = (SMDockEntry *)[scroll viewWithTag:kEntryTag];
    if (!entry) {
        entry = [[SMDockEntry alloc] initWithFrame:CGRectZero];
        entry.tag = kEntryTag;
        entry.owner = vc;
        [scroll addSubview:entry];
    }
    entry.layer.zPosition = 50;

    SMDockEntry *ghost = (SMDockEntry *)[scroll viewWithTag:kGhostTag];
    if (!ghost) {
        ghost = [[SMDockEntry alloc] initWithFrame:CGRectZero];
        ghost.tag = kGhostTag;
        ghost.owner = vc;
        ((UILabel *)[ghost viewWithTag:2]).text = @"Невидимка";
        ((UIImageView *)[ghost viewWithTag:1]).image = [UIImage systemImageNamed:@"eye.slash"];
        [scroll addSubview:ghost];
    }
    ghost.layer.zPosition = 50;

    CGFloat width = scroll.bounds.size.width;
    CGFloat side = 16;
    CGFloat height = 52;
    CGFloat y = scroll.contentSize.height + 14;
    entry.frame = CGRectMake(side, y, width - side * 2, height);
    ghost.frame = CGRectMake(side, CGRectGetMaxY(entry.frame) + 10, width - side * 2, height);

    CGFloat extra = height * 2 + 46;
    NSNumber *base = objc_getAssociatedObject(scroll, "sm_baseBottom");
    if (!base) {
        base = @(scroll.contentInset.bottom);
        objc_setAssociatedObject(scroll, "sm_baseBottom", base, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIEdgeInsets inset = scroll.contentInset;
    CGFloat target = base.doubleValue + extra;
    if (fabs(inset.bottom - target) > 0.5) {
        inset.bottom = target;
        scroll.contentInset = inset;
        scroll.verticalScrollIndicatorInsets = inset;
    }
    [scroll bringSubviewToFront:entry];
    [scroll bringSubviewToFront:ghost];

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

static void scheduleRestyle(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ styleAllBars(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        styleAllBars();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        styleAllBars();
    });
}

static IMP orig_interactive;

static BOOL swizzled_interactive(id self, SEL _cmd) {
    if (ghostMode()) return NO;
    return ((BOOL (*)(id, SEL))orig_interactive)(self, _cmd);
}

static IMP orig_markChat;

static void *swizzled_markChat(id self, SEL _cmd, id chat, id readTo, id messageId) {
    if (antiRead()) return NULL;
    return ((void *(*)(id, SEL, id, id, id))orig_markChat)(self, _cmd, chat, readTo, messageId);
}

static void hookAntiRead(void) {
    static BOOL hooked;
    if (hooked) return;
    SEL sel = @selector(markChat:asReadTo:messageId:);
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;
    for (unsigned int i = 0; i < count && !hooked; i++) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(classes[i], &methodCount);
        for (unsigned int j = 0; j < methodCount; j++) {
            if (method_getName(methods[j]) != sel) continue;
            orig_markChat = method_getImplementation(methods[j]);
            method_setImplementation(methods[j], (IMP)swizzled_markChat);
            hooked = YES;
            break;
        }
        free(methods);
    }
    free(classes);
}

static IMP orig_deleteLocal;

static id swizzled_deleteLocal(id self, SEL _cmd, id messageIds, id chat) {
    if (keepDeleted()) return nil;
    return ((id (*)(id, SEL, id, id))orig_deleteLocal)(self, _cmd, messageIds, chat);
}

static void hookKeepDeleted(void) {
    static BOOL hooked;
    if (hooked) return;
    SEL sel = @selector(deleteLocallyMessagesWithIds:updateChat:);
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;
    for (unsigned int i = 0; i < count && !hooked; i++) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(classes[i], &methodCount);
        for (unsigned int j = 0; j < methodCount; j++) {
            if (method_getName(methods[j]) != sel) continue;
            orig_deleteLocal = method_getImplementation(methods[j]);
            method_setImplementation(methods[j], (IMP)swizzled_deleteLocal);
            hooked = YES;
            break;
        }
        free(methods);
    }
    free(classes);
}

static Ivar sm_textIvar(id text, NSString **value) {
    if (!text || [text isKindOfClass:[NSString class]]) {
        if (value && [text isKindOfClass:[NSString class]]) *value = text;
        return NULL;
    }
    Class cls = object_getClass(text);
    Ivar fallback = NULL;
    NSString *fallbackValue = nil;
    while (cls) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *enc = ivar_getTypeEncoding(ivars[i]);
            const char *name = ivar_getName(ivars[i]);
            if (!enc || strcmp(enc, "@\"NSString\"") != 0) continue;
            id current = object_getIvar(text, ivars[i]);
            if (![current isKindOfClass:[NSString class]] || ![current length]) continue;
            BOOL named = name && (strstr(name, "text") || strstr(name, "Text") || strstr(name, "string") || strstr(name, "String"));
            if (named) {
                if (value) *value = current;
                Ivar found = ivars[i];
                free(ivars);
                return found;
            }
            if (!fallback) {
                fallback = ivars[i];
                fallbackValue = current;
            }
        }
        free(ivars);
        cls = class_getSuperclass(cls);
    }
    if (fallback && value) *value = fallbackValue;
    return fallback;
}

static IMP orig_setMessageText;

static void swizzled_setMessageText(id self, SEL _cmd, id newText) {
    if (keepEdits() && newText && [self respondsToSelector:@selector(messageText)]) {
        id oldText = ((id (*)(id, SEL))objc_msgSend)(self, @selector(messageText));
        NSString *oldString = nil;
        NSString *newString = nil;
        sm_textIvar(oldText, &oldString);
        Ivar ivar = sm_textIvar(newText, &newString);
        if (oldString.length && newString.length && ![oldString isEqualToString:newString] && [newString rangeOfString:@"—— было ——"].location == NSNotFound) {
            NSString *combined = [NSString stringWithFormat:@"%@\n—— было ——\n%@", newString, oldString];
            if (ivar) object_setIvar(newText, ivar, combined);
        }
    }
    ((void (*)(id, SEL, id))orig_setMessageText)(self, _cmd, newText);
}

static void hookKeepEdits(void) {
    static BOOL hooked;
    if (hooked) return;
    Class cls = objc_getClass("OKMMessage");
    SEL sel = @selector(setMessageText:);
    while (cls && !hooked) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int i = 0; i < methodCount; i++) {
            if (method_getName(methods[i]) != sel) continue;
            orig_setMessageText = method_getImplementation(methods[i]);
            method_setImplementation(methods[i], (IMP)swizzled_setMessageText);
            hooked = YES;
            break;
        }
        free(methods);
        cls = class_getSuperclass(cls);
    }
}

static void hookGhost(void) {
    static BOOL hooked;
    if (hooked) return;
    Class cls = objc_getClass("OKMMessengerClient");
    if (!cls) return;
    SEL sel = @selector(interactive);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    hooked = YES;
    orig_interactive = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (!class_addMethod(cls, sel, (IMP)swizzled_interactive, types)) {
        method_setImplementation(class_getInstanceMethod(cls, sel), (IMP)swizzled_interactive);
    }
}

static void resolveAndHook(void) {
    static BOOL hooked;
    TabBarClass = objc_getClass("_TtC7OMUIKit6TabBar");
    SettingsClass = objc_getClass("_TtC10SettingsUI22SettingsViewController");
    styleAllBars();
    hookGhost();
    hookAntiRead();
    hookKeepDeleted();
    hookKeepEdits();
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

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    static id activeObserver;
    static id foregroundObserver;
    activeObserver = [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        scheduleRestyle();
    }];
    foregroundObserver = [center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        scheduleRestyle();
    }];
}

static void hookLiquidGlassFlag(void);

__attribute__((constructor))
static void safeMAXDockInit(void) {
    hookLiquidGlassFlag();
    hookGhost();
    hookAntiRead();
    hookKeepDeleted();
    hookKeepEdits();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        resolveAndHook();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        resolveAndHook();
    });
}

static IMP orig_infoDictionary;
static IMP orig_infoKey;
static BOOL g_inInfo;

static NSDictionary *swizzled_infoDictionary(id self, SEL _cmd) {
    NSDictionary *dict = ((NSDictionary *(*)(id, SEL))orig_infoDictionary)(self, _cmd);
    if (g_inInfo || self != [NSBundle mainBundle] || ![dict isKindOfClass:[NSDictionary class]]) return dict;
    NSMutableDictionary *copy = [dict mutableCopy];
    copy[@"UIDesignRequiresCompatibility"] = @NO;
    return copy;
}

static id swizzled_infoKey(id self, SEL _cmd, NSString *key) {
    if (!g_inInfo && self == [NSBundle mainBundle] && [key isEqualToString:@"UIDesignRequiresCompatibility"]) {
        return @NO;
    }
    return ((id (*)(id, SEL, NSString *))orig_infoKey)(self, _cmd, key);
}

static void hookLiquidGlassFlag(void) {
    static BOOL hooked;
    if (hooked) return;
    hooked = YES;
    Method info = class_getInstanceMethod([NSBundle class], @selector(infoDictionary));
    orig_infoDictionary = method_getImplementation(info);
    method_setImplementation(info, (IMP)swizzled_infoDictionary);
    Method key = class_getInstanceMethod([NSBundle class], @selector(objectForInfoDictionaryKey:));
    orig_infoKey = method_getImplementation(key);
    method_setImplementation(key, (IMP)swizzled_infoKey);
}
