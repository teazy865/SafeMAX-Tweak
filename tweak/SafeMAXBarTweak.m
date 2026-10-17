#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <dlfcn.h>
#import <limits.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <UserNotifications/UserNotifications.h>
#import <CoreLocation/CoreLocation.h>

// SafeMAX bottom dock is OMUIKit.TabBar, not UITabBar.
// Never hide or fade existing subviews: that removes the icons.

static NSString *const kShowLabelsKey = @"SafeMAX_ShowLabels";
static NSString *const kFloatingKey = @"SafeMAX_FloatingDock";
static NSString *const kOrderKey = @"SafeMAX_TabOrder";
static NSString *const kGhostKey = @"SafeMAX_GhostMode";
static NSString *const kAntiReadKey = @"SafeMAX_AntiRead";
static NSString *const kKeepDeletedKey = @"SafeMAX_KeepDeleted";
static NSString *const kKeepEditsKey = @"SafeMAX_KeepEdits";
static NSString *const kBgNotifyKey = @"SafeMAX_BgNotify";

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

static BOOL g_keepDeleted;
static BOOL g_keepDeletedLoaded;

static BOOL keepDeleted(void) {
    if (!g_keepDeletedLoaded) {
        id obj = [[NSUserDefaults standardUserDefaults] objectForKey:kKeepDeletedKey];
        g_keepDeleted = obj ? [obj boolValue] : NO;
        g_keepDeletedLoaded = YES;
    }
    return g_keepDeleted;
}

static BOOL keepEdits(void) {
    id obj = [[NSUserDefaults standardUserDefaults] objectForKey:kKeepEditsKey];
    return obj ? [obj boolValue] : NO;
}

static BOOL bgNotify(void) {
    id obj = [[NSUserDefaults standardUserDefaults] objectForKey:kBgNotifyKey];
    return obj ? [obj boolValue] : NO;
}

static void sm_bgNotifyChanged(BOOL on);

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
        case 4: key = kBgNotifyKey; break;
        default: break;
    }
    [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:key];
    if (key == kKeepDeletedKey) {
        g_keepDeleted = sender.on;
        g_keepDeletedLoaded = YES;
    }
    if (key == kBgNotifyKey) sm_bgNotifyChanged(sender.on);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 5; }

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath { return 88; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"g"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"g"];
    cell.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.textLabel.numberOfLines = 1;
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:0.55];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
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
            cell.detailTextLabel.text = @"Остаются после перезапуска, на пузыре красная корзина";
            on = keepDeleted();
            break;
        case 3:
            cell.textLabel.text = @"История правок";
            cell.detailTextLabel.text = @"Старый текст остаётся под новым";
            on = keepEdits();
            break;
        default:
            cell.textLabel.text = @"Фоновые уведомления";
            cell.detailTextLabel.text = @"Баннер, когда MAX свёрнут, но не выгружен";
            on = bgNotify();
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

static void sm_updateDeletedCell(UIView *cell);

static void swizzled_layout(id self, SEL _cmd) {
    ((void (*)(id, SEL))orig_layout)(self, _cmd);
    if ([self isKindOfClass:[UIView class]]) sm_updateDeletedCell((UIView *)self);
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
static IMP orig_setStatus;
static IMP orig_status;
static IMP orig_messagesDeleted;
static IMP orig_delayedDeleted;
static IMP orig_sendNextSubject;
static IMP orig_sendNextReplay;
static IMP orig_sendNextBehavior;
static IMP orig_sendNextPass;
static Class smMessageClass;

static BOOL sm_hook_own(Class cls, const char *selName, IMP replacement, IMP *origOut) {
    if (!cls || !origOut || *origOut) return origOut && *origOut;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; methods && i < count; i++) {
        const char *name = sel_getName(method_getName(methods[i]));
        if (!name || strcmp(name, selName) != 0) continue;
        *origOut = method_getImplementation(methods[i]);
        if (*origOut != replacement) method_setImplementation(methods[i], replacement);
        found = YES;
        break;
    }
    free(methods);
    return found;
}

static BOOL sm_isRemovalEvent(id value) {
    if (!value) return NO;
    const char *name = class_getName(object_getClass(value));
    if (!name || !strstr(name, "ChatEvent")) return NO;
    SEL typeSel = @selector(type);
    if (![value respondsToSelector:typeSel]) return NO;
    unsigned long long type = ((unsigned long long (*)(id, SEL))objc_msgSend)(value, typeSel);
    return type == 3;
}

static void sm_noteDeletedPayload(id ids, id chat, id serviceOwner);
static void sm_rememberDeletedText(NSString *text);
static NSString *sm_messageBody(id message);
static void sm_refreshDeletedLooks(void);
static void sm_updateDeletedCell(UIView *cell);
static NSDictionary *sm_snapshot(id message);
static void sm_rememberSnapshot(NSDictionary *snap);
static void sm_noteHistoryPage(id value);
static void sm_captureOpenPages(void);
static void sm_reloadHistory(void);
static void sm_keepInsteadOfDelete(id service, id ids);
static id sm_call(id obj, const char *selName);
static void sm_prefixDeletedMark(id message);

static id swizzled_deleteLocal(id self, SEL _cmd, id messageIds, id chat) {
    if (keepDeleted()) {
        sm_captureOpenPages();
        sm_noteDeletedPayload(messageIds, chat, self);
        return nil;
    }
    return ((id (*)(id, SEL, id, id))orig_deleteLocal)(self, _cmd, messageIds, chat);
}

static void swizzled_setStatus(id self, SEL _cmd, NSUInteger status) {
    if (keepDeleted() && status == 2 && smMessageClass && [self isKindOfClass:smMessageClass]) {
        NSDictionary *snap = sm_snapshot(self);
        if (snap) sm_rememberSnapshot(snap);
        else sm_rememberDeletedText(sm_messageBody(self));
        sm_refreshDeletedLooks();
        return;
    }
    ((void (*)(id, SEL, NSUInteger))orig_setStatus)(self, _cmd, status);
}

static NSUInteger swizzled_status(id self, SEL _cmd) {
    NSUInteger status = ((NSUInteger (*)(id, SEL))orig_status)(self, _cmd);
    if (keepDeleted() && status == 2 && smMessageClass && [self isKindOfClass:smMessageClass]) return 0;
    return status;
}

static void swizzled_messagesDeleted(id self, SEL _cmd, id messages, id chat) {
    if (keepDeleted()) {
        sm_noteDeletedPayload(messages, chat, self);
        return;
    }
    ((void (*)(id, SEL, id, id))orig_messagesDeleted)(self, _cmd, messages, chat);
}

static void swizzled_delayedDeleted(id self, SEL _cmd, id notification) {
    if (keepDeleted()) {
        id ids = [notification respondsToSelector:@selector(messageIds)] ? ((id (*)(id, SEL))objc_msgSend)(notification, @selector(messageIds)) : notification;
        id chat = [notification respondsToSelector:@selector(chat)] ? ((id (*)(id, SEL))objc_msgSend)(notification, @selector(chat)) : nil;
        sm_noteDeletedPayload(ids, chat, self);
        return;
    }
    ((void (*)(id, SEL, id))orig_delayedDeleted)(self, _cmd, notification);
}

static void swizzled_sendNextSubject(id self, SEL _cmd, id value) {
    if (keepDeleted() && sm_isRemovalEvent(value)) return;
    if (keepDeleted()) sm_noteHistoryPage(value);
    ((void (*)(id, SEL, id))orig_sendNextSubject)(self, _cmd, value);
}

static void swizzled_sendNextReplay(id self, SEL _cmd, id value) {
    if (keepDeleted() && sm_isRemovalEvent(value)) return;
    if (keepDeleted()) sm_noteHistoryPage(value);
    ((void (*)(id, SEL, id))orig_sendNextReplay)(self, _cmd, value);
}

static void swizzled_sendNextBehavior(id self, SEL _cmd, id value) {
    if (keepDeleted() && sm_isRemovalEvent(value)) return;
    if (keepDeleted()) sm_noteHistoryPage(value);
    ((void (*)(id, SEL, id))orig_sendNextBehavior)(self, _cmd, value);
}

static void swizzled_sendNextPass(id self, SEL _cmd, id value) {
    if (keepDeleted() && sm_isRemovalEvent(value)) return;
    if (keepDeleted()) sm_noteHistoryPage(value);
    ((void (*)(id, SEL, id))orig_sendNextPass)(self, _cmd, value);
}

static IMP orig_removeObject;
static IMP orig_removeObjects;
static IMP orig_removeWithRowid;
static IMP orig_removeCollectionKey;
static IMP orig_setDbObject;
static IMP orig_setMessages;
static IMP orig_getMessages;
static BOOL g_inMerge;
static char smMergedSourceKey;
static char smMergedValueKey;
static NSHashTable *smSeenPages;
static NSMapTable *smPageSnapshots;
static IMP orig_deletePks;
static IMP orig_deletePksPublic;
static IMP orig_deleteComplaint;
static IMP orig_deleteLegacy;
static IMP orig_processPlain;
static IMP orig_processSparse;
static IMP orig_processChunk;
static IMP orig_processChunkNotify;

static BOOL sm_historyGuard(void) {
    return NO;
}

static void sm_trackPage(id page) {
    if (!page || g_inMerge) return;
    const char *name = class_getName(object_getClass(page));
    if (!name || !strstr(name, "HistoryPage")) return;
    if (!smSeenPages) smSeenPages = [NSHashTable weakObjectsHashTable];
    [smSeenPages addObject:page];
}

static void sm_rememberLongerPage(id page, id messages) {
    if (!page || ![messages isKindOfClass:[NSArray class]] || [(NSArray *)messages count] == 0) return;
    if (!smPageSnapshots) smPageSnapshots = [NSMapTable weakToStrongObjectsMapTable];
    id existing = [smPageSnapshots objectForKey:page];
    if ([existing isKindOfClass:[NSArray class]] && [(NSArray *)existing count] >= [(NSArray *)messages count]) return;
    [smPageSnapshots setObject:[(NSArray *)messages copy] forKey:page];
}

static id sm_longerSnapshot(id page, id messages) {
    if (!smPageSnapshots || !page) return messages;
    id snap = [smPageSnapshots objectForKey:page];
    if (![snap isKindOfClass:[NSArray class]] || [(NSArray *)snap count] == 0) return messages;
    NSUInteger newCount = [messages respondsToSelector:@selector(count)] ? [(NSArray *)messages count] : 0;
    if ([(NSArray *)snap count] > newCount) return snap;
    return messages;
}

static void sm_captureOpenPages(void) {
    if (!keepDeleted() || !smSeenPages || !orig_getMessages) return;
    for (id page in smSeenPages) {
        id current = ((id (*)(id, SEL))orig_getMessages)(page, @selector(messages));
        sm_rememberLongerPage(page, current);
    }
}

static BOOL sm_isChunkCollection(id collection) {
    return [collection isKindOfClass:[NSString class]] && [(NSString *)collection isEqualToString:@"history_chunks"];
}

static BOOL sm_sameId(id message, id needle) {
    if (!message || !needle || message == needle) return message == needle;
    id pk = sm_call(message, "primaryKey");
    if (pk && ([pk isEqual:needle] || [[pk description] isEqual:[needle description]])) return YES;
    id sid = sm_call(message, "serverId");
    if (!sid) return NO;
    if ([sid isEqual:needle] || [[sid description] isEqual:[needle description]]) return YES;
    if ([sid respondsToSelector:@selector(longLongValue)] && [needle respondsToSelector:@selector(longLongValue)]) {
        long long left = [sid longLongValue];
        long long right = [needle longLongValue];
        if (left && left == right) return YES;
    }
    return NO;
}

static void sm_markIdsInOpenPages(id ids) {
    NSMutableArray *items = [NSMutableArray array];
    if ([ids isKindOfClass:[NSArray class]] || [ids isKindOfClass:[NSSet class]] || [ids isKindOfClass:[NSOrderedSet class]]) {
        for (id item in ids) if (item) [items addObject:item];
    } else if (ids) {
        [items addObject:ids];
    }
    if (items.count == 0 || !smSeenPages || !orig_getMessages) return;
    for (id page in smSeenPages) {
        id current = ((id (*)(id, SEL))orig_getMessages)(page, @selector(messages));
        if (![current respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) continue;
        for (id message in current) {
            for (id item in items) {
                if (sm_sameId(message, item)) sm_prefixDeletedMark(message);
            }
        }
    }
}

static void sm_keepInsteadOfDelete(id service, id ids) {
    sm_captureOpenPages();
    sm_markIdsInOpenPages(ids);
    sm_noteDeletedPayload(ids, nil, service);
    sm_reloadHistory();
}

static void swizzled_deletePks(id self, SEL _cmd, id pks, BOOL deleteForAll, id tasks) {
    if (keepDeleted()) {
        sm_keepInsteadOfDelete(self, pks);
        return;
    }
    if (orig_deletePks) ((void (*)(id, SEL, id, BOOL, id))orig_deletePks)(self, _cmd, pks, deleteForAll, tasks);
}

static void swizzled_deleteComplaint(id self, SEL _cmd, id pks, BOOL deleteForAll, id complaint) {
    if (keepDeleted()) {
        sm_keepInsteadOfDelete(self, pks);
        return;
    }
    if (orig_deleteComplaint) ((void (*)(id, SEL, id, BOOL, id))orig_deleteComplaint)(self, _cmd, pks, deleteForAll, complaint);
}

static void swizzled_deleteLegacy(id self, SEL _cmd, id pks, BOOL deleteForAll, id complaint) {
    if (keepDeleted()) {
        sm_keepInsteadOfDelete(self, pks);
        return;
    }
    if (orig_deleteLegacy) ((void (*)(id, SEL, id, BOOL, id))orig_deleteLegacy)(self, _cmd, pks, deleteForAll, complaint);
}

static void swizzled_deletePksPublic(id self, SEL _cmd, id pks, BOOL deleteForAll) {
    if (keepDeleted()) {
        sm_keepInsteadOfDelete(self, pks);
        return;
    }
    if (orig_deletePksPublic) ((void (*)(id, SEL, id, BOOL))orig_deletePksPublic)(self, _cmd, pks, deleteForAll);
}

static id swizzled_processPlain(id self, SEL _cmd, id response, id chatId, BOOL lastPage, BOOL firstPage) {
    if (sm_historyGuard()) return nil;
    return ((id (*)(id, SEL, id, id, BOOL, BOOL))orig_processPlain)(self, _cmd, response, chatId, lastPage, firstPage);
}

static id swizzled_processSparse(id self, SEL _cmd, id response, id chatId, BOOL lastPage, BOOL firstPage, BOOL sparse) {
    if (sm_historyGuard()) return nil;
    return ((id (*)(id, SEL, id, id, BOOL, BOOL, BOOL))orig_processSparse)(self, _cmd, response, chatId, lastPage, firstPage, sparse);
}

static void swizzled_processChunk(id self, SEL _cmd, id chunk) {
    if (sm_historyGuard()) return;
    if (orig_processChunk) ((void (*)(id, SEL, id))orig_processChunk)(self, _cmd, chunk);
}

static void swizzled_processChunkNotify(id self, SEL _cmd, id chunk, BOOL notify) {
    if (sm_historyGuard()) return;
    if (orig_processChunkNotify) ((void (*)(id, SEL, id, BOOL))orig_processChunkNotify)(self, _cmd, chunk, notify);
}

static BOOL sm_isMessagesCollection(id collection) {
    return [collection isKindOfClass:[NSString class]] && [(NSString *)collection isEqualToString:@"messages"];
}

static BOOL sm_isKeptKey(id key);

static void swizzled_removeObject(id self, SEL _cmd, id key, id collection) {
    if (sm_historyGuard() && sm_isChunkCollection(collection)) return;
    if (keepDeleted() && sm_isMessagesCollection(collection) && sm_isKeptKey(key)) return;
    ((void (*)(id, SEL, id, id))orig_removeObject)(self, _cmd, key, collection);
}

static void swizzled_removeWithRowid(id self, SEL _cmd, id key, id collection, long long rowid) {
    if (sm_historyGuard() && sm_isChunkCollection(collection)) return;
    if (keepDeleted() && sm_isMessagesCollection(collection) && sm_isKeptKey(key)) return;
    ((void (*)(id, SEL, id, id, long long))orig_removeWithRowid)(self, _cmd, key, collection, rowid);
}

static void swizzled_removeCollectionKey(id self, SEL _cmd, id collectionKey, long long rowid) {
    if (sm_historyGuard() && collectionKey) {
        id collection = nil;
        SEL collectionSel = sel_registerName("collection");
        if ([collectionKey respondsToSelector:collectionSel]) collection = ((id (*)(id, SEL))objc_msgSend)(collectionKey, collectionSel);
        if (sm_isChunkCollection(collection)) return;
    }
    ((void (*)(id, SEL, id, long long))orig_removeCollectionKey)(self, _cmd, collectionKey, rowid);
}

static void swizzled_removeObjects(id self, SEL _cmd, id keys, id collection) {
    if (sm_historyGuard() && sm_isChunkCollection(collection)) return;
    if (keepDeleted() && sm_isMessagesCollection(collection) && [keys respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)]) {
        NSMutableArray *rest = [NSMutableArray array];
        for (id key in keys) {
            if (!sm_isKeptKey(key)) [rest addObject:key];
        }
        if (rest.count == 0) return;
        keys = rest;
    }
    ((void (*)(id, SEL, id, id))orig_removeObjects)(self, _cmd, keys, collection);
}

static void swizzled_setDbObject(id self, SEL _cmd, id object, id key, id collection) {
    if (keepDeleted() && sm_isMessagesCollection(collection) && sm_isKeptKey(key)) {
        if (!object) return;
        if (orig_status && smMessageClass && [object isKindOfClass:smMessageClass]) {
            NSUInteger raw = ((NSUInteger (*)(id, SEL))orig_status)(object, @selector(status));
            if (raw == 2) return;
        }
    }
    ((void (*)(id, SEL, id, id, id))orig_setDbObject)(self, _cmd, object, key, collection);
}

static id sm_mergeKeptInto(id page, id messages);

static id swizzled_getMessages(id self, SEL _cmd) {
    id messages = ((id (*)(id, SEL))orig_getMessages)(self, _cmd);
    if (!keepDeleted() || g_inMerge) return messages;
    sm_trackPage(self);
    sm_rememberLongerPage(self, messages);
    messages = sm_longerSnapshot(self, messages);
    id cachedSource = objc_getAssociatedObject(self, &smMergedSourceKey);
    id cachedMerged = objc_getAssociatedObject(self, &smMergedValueKey);
    if (cachedSource == messages && cachedMerged) return cachedMerged;
    g_inMerge = YES;
    id merged = sm_mergeKeptInto(self, messages);
    g_inMerge = NO;
    if (!merged) merged = messages;
    objc_setAssociatedObject(self, &smMergedSourceKey, messages, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &smMergedValueKey, merged, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return merged;
}

static void swizzled_setMessages(id self, SEL _cmd, id messages) {
    if (keepDeleted() && !g_inMerge) {
        const char *name = class_getName(object_getClass(self));
        if (name && strstr(name, "HistoryPage")) {
            sm_trackPage(self);
            id preserved = sm_longerSnapshot(self, messages);
            if (preserved != messages) messages = preserved;
            g_inMerge = YES;
            id merged = sm_mergeKeptInto(self, messages);
            g_inMerge = NO;
            if (merged) messages = merged;
            sm_rememberLongerPage(self, messages);
            objc_setAssociatedObject(self, &smMergedSourceKey, nil, OBJC_ASSOCIATION_ASSIGN);
            objc_setAssociatedObject(self, &smMergedValueKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
    }
    ((void (*)(id, SEL, id))orig_setMessages)(self, _cmd, messages);
}

static void hookKeepDeleted(void) {
    if (!smMessageClass) smMessageClass = objc_getClass("OKMMessage");
    sm_hook_own(smMessageClass, "setStatus:", (IMP)swizzled_setStatus, &orig_setStatus);
    sm_hook_own(smMessageClass, "status", (IMP)swizzled_status, &orig_status);
    sm_hook_own(objc_getClass("OKMChatService"), "deleteLocallyMessagesWithIds:updateChat:", (IMP)swizzled_deleteLocal, &orig_deleteLocal);
    sm_hook_own(objc_getClass("OKMChatService"), "deleteMessagesWithPks:deleteForAll:", (IMP)swizzled_deletePksPublic, &orig_deletePksPublic);
    sm_hook_own(objc_getClass("OKMChatService"), "_deleteMessagesWithPks:deleteForAll:enqueueTasks:", (IMP)swizzled_deletePks, &orig_deletePks);
    sm_hook_own(objc_getClass("OKMChatService"), "_deleteMessagesWithPks:deleteForAll:withComplaint:", (IMP)swizzled_deleteComplaint, &orig_deleteComplaint);
    sm_hook_own(objc_getClass("OKMChatService"), "_deleteMessagesWithPks:deleteForAll:withLegacyComplaint:", (IMP)swizzled_deleteLegacy, &orig_deleteLegacy);
    Class listener = objc_getClass("OKMMessageDeleteListener");
    sm_hook_own(listener, "_messagesDeleted:inChat:", (IMP)swizzled_messagesDeleted, &orig_messagesDeleted);
    sm_hook_own(listener, "_delayedMessagesDeleted:", (IMP)swizzled_delayedDeleted, &orig_delayedDeleted);
    sm_hook_own(objc_getClass("RACSubject"), "sendNext:", (IMP)swizzled_sendNextSubject, &orig_sendNextSubject);
    sm_hook_own(objc_getClass("RACReplaySubject"), "sendNext:", (IMP)swizzled_sendNextReplay, &orig_sendNextReplay);
    sm_hook_own(objc_getClass("RACBehaviorSubject"), "sendNext:", (IMP)swizzled_sendNextBehavior, &orig_sendNextBehavior);
    sm_hook_own(objc_getClass("RACPassthroughSubscriber"), "sendNext:", (IMP)swizzled_sendNextPass, &orig_sendNextPass);
    Class writeTx = objc_getClass("YapDatabaseReadWriteTransaction");
    sm_hook_own(writeTx, "removeObjectForKey:inCollection:", (IMP)swizzled_removeObject, &orig_removeObject);
    sm_hook_own(writeTx, "removeObjectForKey:inCollection:withRowid:", (IMP)swizzled_removeWithRowid, &orig_removeWithRowid);
    sm_hook_own(writeTx, "removeObjectForCollectionKey:withRowid:", (IMP)swizzled_removeCollectionKey, &orig_removeCollectionKey);
    sm_hook_own(writeTx, "removeObjectsForKeys:inCollection:", (IMP)swizzled_removeObjects, &orig_removeObjects);
    sm_hook_own(writeTx, "setObject:forKey:inCollection:", (IMP)swizzled_setDbObject, &orig_setDbObject);
    Class pageClass = objc_getClass("OKMHistoryPage");
    sm_hook_own(pageClass, "setMessages:", (IMP)swizzled_setMessages, &orig_setMessages);
    sm_hook_own(pageClass, "messages", (IMP)swizzled_getMessages, &orig_getMessages);
    Class history = objc_getClass("OKMHistoryService");
    sm_hook_own(history, "_processHistoryResponse:chatId:isLastPage:isFirstPage:", (IMP)swizzled_processPlain, &orig_processPlain);
    sm_hook_own(history, "_processHistoryResponse:chatId:isLastPage:isFirstPage:sparse:", (IMP)swizzled_processSparse, &orig_processSparse);
    Class loader = objc_getClass("OKMChatHistoryLoader");
    sm_hook_own(loader, "processHistoryChunk:", (IMP)swizzled_processChunk, &orig_processChunk);
    sm_hook_own(loader, "processHistoryChunk:notify:", (IMP)swizzled_processChunkNotify, &orig_processChunkNotify);
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

static const NSInteger kDeletedBadgeTag = 0x5AFD;
static NSMutableOrderedSet<NSString *> *smDeletedBodies;
static NSMutableArray *smKept;
static NSMutableSet<NSString *> *smKeptKeys;
static NSLock *smDeletedLock;
static NSArray *g_lookupIds;
static id g_lookupChat;
static NSMutableArray *g_lookupSnaps;
static NSMutableArray *g_lookupMessages;

static void sm_loadDeletedBodies(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        smDeletedLock = [[NSLock alloc] init];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSArray *saved = [defaults arrayForKey:@"SafeMAX_DeletedBodies"];
        smDeletedBodies = saved ? [NSMutableOrderedSet orderedSetWithArray:saved] : [NSMutableOrderedSet orderedSet];
        NSArray *kept = [defaults arrayForKey:@"SafeMAX_KeptMessages"];
        smKept = kept ? [kept mutableCopy] : [NSMutableArray array];
        smKeptKeys = [NSMutableSet set];
        for (NSDictionary *rec in smKept) {
            if (![rec isKindOfClass:[NSDictionary class]]) continue;
            id pk = rec[@"pk"];
            id sid = rec[@"sid"];
            if ([pk isKindOfClass:[NSString class]] && [pk length]) [smKeptKeys addObject:pk];
            if ([sid respondsToSelector:@selector(stringValue)]) {
                NSString *text = [sid stringValue];
                if (text.length) [smKeptKeys addObject:text];
            }
        }
    });
}

static BOOL sm_isDeletedBody(NSString *text) {
    if (text.length == 0) return NO;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return NO;
    if ([trimmed rangeOfString:@"❌"].location != NSNotFound) return YES;
    sm_loadDeletedBodies();
    [smDeletedLock lock];
    BOOL hit = [smDeletedBodies containsObject:trimmed];
    if (!hit && trimmed.length > 2) {
        for (NSString *body in smDeletedBodies) {
            if (body.length >= 2 && [trimmed rangeOfString:body].location != NSNotFound && trimmed.length <= body.length + 16) {
                hit = YES;
                break;
            }
        }
    }
    [smDeletedLock unlock];
    return hit;
}

static BOOL sm_isKeptKey(id key) {
    if (!key) return NO;
    NSString *text = [key isKindOfClass:[NSString class]] ? key : ([key respondsToSelector:@selector(stringValue)] ? [key stringValue] : nil);
    if (text.length == 0) return NO;
    sm_loadDeletedBodies();
    [smDeletedLock lock];
    BOOL hit = [smKeptKeys containsObject:text];
    [smDeletedLock unlock];
    return hit;
}

static BOOL sm_isKeptServerId(id value) {
    if (![value respondsToSelector:@selector(longLongValue)]) return NO;
    long long number = ((long long (*)(id, SEL))objc_msgSend)(value, @selector(longLongValue));
    if (number < 10000) return NO;
    return sm_isKeptKey([@(number) stringValue]);
}

static NSString *sm_stripDeletedMark(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return text;
    NSString *clean = text;
    while (clean.length) {
        if ([clean hasPrefix:@"❌ "]) {
            clean = [clean substringFromIndex:2];
            continue;
        }
        if ([clean hasPrefix:@"❌"]) {
            clean = [clean substringFromIndex:1];
            continue;
        }
        break;
    }
    return [clean isEqualToString:text] ? text : clean;
}

static void sm_rememberDeletedText(NSString *text) {
    text = sm_stripDeletedMark(text);
    if (text.length == 0) return;
    sm_loadDeletedBodies();
    NSArray<NSString *> *parts = [text componentsSeparatedByString:@"\n—— было ——\n"];
    BOOL changed = NO;
    [smDeletedLock lock];
    for (NSString *part in parts) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0 || [smDeletedBodies containsObject:trimmed]) continue;
        [smDeletedBodies addObject:trimmed];
        changed = YES;
    }
    while (smDeletedBodies.count > 400) [smDeletedBodies removeObjectAtIndex:0];
    NSArray *snapshot = changed ? [smDeletedBodies array] : nil;
    [smDeletedLock unlock];
    if (snapshot) [[NSUserDefaults standardUserDefaults] setObject:snapshot forKey:@"SafeMAX_DeletedBodies"];
}

static id sm_call(id obj, const char *selName) {
    SEL sel = sel_registerName(selName);
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

static long long sm_callLL(id obj, const char *selName) {
    SEL sel = sel_registerName(selName);
    if (!obj || ![obj respondsToSelector:sel]) return 0;
    return ((long long (*)(id, SEL))objc_msgSend)(obj, sel);
}

static id sm_plistId(id value) {
    if (!value || value == (id)kCFNull) return nil;
    if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) return value;
    if ([value respondsToSelector:@selector(longLongValue)]) {
        return @(((long long (*)(id, SEL))objc_msgSend)(value, @selector(longLongValue)));
    }
    return nil;
}

static NSDictionary *sm_snapshot(id message) {
    if (!message || [message isKindOfClass:[NSNumber class]] || [message isKindOfClass:[NSString class]]) return nil;
    if (![message respondsToSelector:@selector(primaryKey)] && ![message respondsToSelector:@selector(messageText)]) return nil;
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    id pk = sm_plistId(sm_call(message, "primaryKey"));
    id sid = sm_plistId(sm_call(message, "serverId"));
    id cid = sm_plistId(sm_call(message, "chatId"));
    id cpk = sm_plistId(sm_call(message, "chatPrimaryKey"));
    id sender = sm_plistId(sm_call(message, "senderId"));
    long long ts = sm_callLL(message, "timestampAsInt");
    NSString *text = sm_messageBody(message);
    if ([pk isKindOfClass:[NSString class]] && [(NSString *)pk length]) record[@"pk"] = pk;
    else if ([pk isKindOfClass:[NSNumber class]]) record[@"pk"] = [pk stringValue];
    if (sid) record[@"sid"] = [sid isKindOfClass:[NSNumber class]] ? sid : @([sid longLongValue]);
    if ([cid isKindOfClass:[NSNumber class]] || [cid isKindOfClass:[NSString class]]) record[@"cid"] = cid;
    if ([cpk isKindOfClass:[NSString class]] && [(NSString *)cpk length]) record[@"cpk"] = cpk;
    if (sender) record[@"sender"] = [sender isKindOfClass:[NSNumber class]] ? sender : @([sender longLongValue]);
    if (ts) record[@"ts"] = @(ts);
    if (text.length) record[@"text"] = text;
    if ([message respondsToSelector:@selector(my)]) {
        BOOL mine = ((BOOL (*)(id, SEL))objc_msgSend)(message, @selector(my));
        record[@"my"] = @(mine);
    }
    return record.count ? record : nil;
}

static void sm_rememberSnapshot(NSDictionary *snap) {
    if (![snap isKindOfClass:[NSDictionary class]]) return;
    NSMutableDictionary *clean = [NSMutableDictionary dictionary];
    for (id key in snap) {
        id value = snap[key];
        if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) clean[key] = value;
    }
    NSString *text = [clean[@"text"] isKindOfClass:[NSString class]] ? clean[@"text"] : nil;
    if (text.length) sm_rememberDeletedText(text);
    NSString *pk = [clean[@"pk"] isKindOfClass:[NSString class]] ? clean[@"pk"] : nil;
    id sid = clean[@"sid"];
    if (!pk.length && !sid && !text.length) return;
    sm_loadDeletedBodies();
    [smDeletedLock lock];
    NSInteger found = NSNotFound;
    long long sidValue = [sid respondsToSelector:@selector(longLongValue)] ? [sid longLongValue] : 0;
    for (NSUInteger i = 0; i < smKept.count; i++) {
        NSDictionary *old = smKept[i];
        if (pk.length && [old[@"pk"] isEqual:pk]) { found = (NSInteger)i; break; }
        if (sidValue && [old[@"sid"] longLongValue] == sidValue) { found = (NSInteger)i; break; }
    }
    if (found != NSNotFound) [smKept replaceObjectAtIndex:(NSUInteger)found withObject:clean];
    else [smKept addObject:clean];
    while (smKept.count > 200) [smKept removeObjectAtIndex:0];
    [smKeptKeys removeAllObjects];
    for (NSDictionary *rec in smKept) {
        id recPk = rec[@"pk"];
        id recSid = rec[@"sid"];
        if ([recPk isKindOfClass:[NSString class]] && [recPk length]) [smKeptKeys addObject:recPk];
        if ([recSid respondsToSelector:@selector(stringValue)]) {
            NSString *sidText = [recSid stringValue];
            if (sidText.length) [smKeptKeys addObject:sidText];
        }
    }
    NSArray *stored = [smKept copy];
    [smDeletedLock unlock];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:stored forKey:@"SafeMAX_KeptMessages"];
    [defaults synchronize];
}

typedef struct {
    void *isa;
    int flags;
    int reserved;
    void *invoke;
    void *descriptor;
} SMBlockLiteral;

static void sm_lookup_invoke(void *block, id transaction) {
    (void)block;
    SEL inChat = sel_registerName("okm_messageForId:inChat:");
    SEL includeRemoved = sel_registerName("okm_messageForId:inChat:includeRemoved:");
    SEL byChatId = sel_registerName("okm_messageForId:chatId:");
    SEL byPk = sel_registerName("okm_messageForPk:");
    id chatId = sm_call(g_lookupChat, "chatId");
    for (id item in g_lookupIds) {
        @try {
            id message = nil;
            if (smMessageClass && [item isKindOfClass:smMessageClass]) message = item;
            if (!message && [transaction respondsToSelector:inChat]) {
                message = ((id (*)(id, SEL, id, id))objc_msgSend)(transaction, inChat, item, g_lookupChat);
            }
            if (!message && [transaction respondsToSelector:includeRemoved]) {
                message = ((id (*)(id, SEL, id, id, BOOL))objc_msgSend)(transaction, includeRemoved, item, g_lookupChat, YES);
            }
            if (!message && chatId && [transaction respondsToSelector:byChatId]) {
                message = ((id (*)(id, SEL, id, id))objc_msgSend)(transaction, byChatId, item, chatId);
            }
            if (!message && [item isKindOfClass:[NSString class]] && [transaction respondsToSelector:byPk]) {
                message = ((id (*)(id, SEL, id))objc_msgSend)(transaction, byPk, item);
            }
            NSDictionary *snap = sm_snapshot(message);
            if (message) [g_lookupMessages addObject:message];
            if (snap) [g_lookupSnaps addObject:snap];
            else {
                NSString *body = sm_messageBody(item);
                if (body.length) [g_lookupSnaps addObject:@{@"text": body}];
            }
        } @catch (__unused NSException *exception) {
        }
    }
}

static id sm_readBlock(void) {
    static SMBlockLiteral block;
    static struct { unsigned long reserved; unsigned long size; const char *signature; const char *layout; } desc;
    static dispatch_once_t once;
    static BOOL ready;
    dispatch_once(&once, ^{
        void *isa = dlsym(RTLD_DEFAULT, "_NSConcreteGlobalBlock");
        if (!isa) return;
        desc.size = sizeof(block);
        desc.signature = "v16@?0@8";
        desc.layout = "\0";
        block.isa = isa;
        block.flags = (1 << 28) | (1 << 30);
        block.invoke = (void *)sm_lookup_invoke;
        block.descriptor = &desc;
        ready = YES;
    });
    return ready ? (__bridge id)&block : nil;
}

static id g_writeMessage;
static id g_writeKey;

static void sm_write_invoke(void *block, id transaction) {
    (void)block;
    if (!g_writeMessage || !g_writeKey) return;
    SEL sel = @selector(setObject:forKey:inCollection:);
    if (![transaction respondsToSelector:sel]) return;
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(transaction, sel, g_writeMessage, g_writeKey, @"messages");
}

static id sm_writeBlock(void) {
    static SMBlockLiteral block;
    static struct { unsigned long reserved; unsigned long size; const char *signature; const char *layout; } desc;
    static dispatch_once_t once;
    static BOOL ready;
    dispatch_once(&once, ^{
        void *isa = dlsym(RTLD_DEFAULT, "_NSConcreteGlobalBlock");
        if (!isa) return;
        desc.size = sizeof(block);
        desc.signature = "v16@?0@8";
        desc.layout = "\0";
        block.isa = isa;
        block.flags = (1 << 28) | (1 << 30);
        block.invoke = (void *)sm_write_invoke;
        block.descriptor = &desc;
        ready = YES;
    });
    return ready ? (__bridge id)&block : nil;
}

static void sm_prefixDeletedMark(id message) {
    if (!message || (smMessageClass && ![message isKindOfClass:smMessageClass] && ![message respondsToSelector:@selector(messageText)])) return;
    id messageText = sm_call(message, "messageText");
    NSString *text = nil;
    Ivar ivar = sm_textIvar(messageText, &text);
    if (text.length == 0) text = sm_messageBody(message);
    NSString *clean = sm_stripDeletedMark(text);
    if (clean.length == 0 || [clean isEqualToString:text]) return;
    if (messageText && [messageText respondsToSelector:@selector(setText:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(messageText, @selector(setText:), clean);
    } else if (ivar && messageText) {
        object_setIvar(messageText, ivar, clean);
    }
}

static void sm_writeMarkedMessage(id connection, id message) {
    if (!connection || !message) return;
    id key = sm_call(message, "primaryKey");
    if (![key isKindOfClass:[NSString class]] || ![key length]) return;
    id block = sm_writeBlock();
    if (!block || ![connection respondsToSelector:@selector(readWriteWithBlock:)]) return;
    g_writeMessage = message;
    g_writeKey = key;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(connection, @selector(readWriteWithBlock:), block);
    } @catch (__unused NSException *exception) {
    }
    g_writeMessage = nil;
    g_writeKey = nil;
}

static void sm_reloadView(UIView *view) {
    const char *name = class_getName(object_getClass(view));
    if (name && strstr(name, "HistoryCollectionView") && [view isKindOfClass:[UICollectionView class]]) {
        [(UICollectionView *)view reloadData];
    }
    for (UIView *subview in view.subviews) sm_reloadView(subview);
}

static void sm_reloadHistory(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in allWindows()) sm_reloadView(window);
        sm_refreshDeletedLooks();
    });
}

static id sm_readConnection(id serviceOwner) {
    id conn = sm_call(serviceOwner, "dbConnection");
    if (!conn) conn = sm_call(serviceOwner, "readConnection");
    if (!conn) {
        id service = sm_call(serviceOwner, "chatService");
        conn = sm_call(service, "readConnection");
        if (!conn) conn = sm_call(service, "dbConnection");
        if (!conn) conn = sm_call(service, "writeConnection");
    }
    return conn;
}

static void sm_noteDeletedPayload(id ids, id chat, id serviceOwner) {
    NSMutableArray *items = [NSMutableArray array];
    if ([ids isKindOfClass:[NSArray class]] || [ids isKindOfClass:[NSSet class]] || [ids isKindOfClass:[NSOrderedSet class]]) {
        for (id item in ids) if (item) [items addObject:item];
    } else if (ids) {
        [items addObject:ids];
    }
    if (items.count == 0) return;
    g_lookupIds = items;
    g_lookupChat = chat;
    g_lookupSnaps = [NSMutableArray array];
    g_lookupMessages = [NSMutableArray array];
    id connection = sm_readConnection(serviceOwner);
    id block = sm_readBlock();
    BOOL ran = NO;
    if (connection && block && [connection respondsToSelector:@selector(readWithBlock:)]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(connection, @selector(readWithBlock:), block);
            ran = YES;
        } @catch (__unused NSException *exception) {
            ran = NO;
        }
    }
    if (!ran) {
        for (id item in items) {
            if (smMessageClass && [item isKindOfClass:smMessageClass]) [g_lookupMessages addObject:item];
            NSDictionary *snap = sm_snapshot(item);
            if (snap) [g_lookupSnaps addObject:snap];
            else {
                NSString *body = sm_messageBody(item);
                if (body.length) [g_lookupSnaps addObject:@{@"text": body}];
            }
        }
    }
    NSArray *snaps = [g_lookupSnaps copy];
    NSArray *messages = [g_lookupMessages copy];
    id chatRef = chat;
    g_lookupIds = nil;
    g_lookupChat = nil;
    g_lookupSnaps = nil;
    g_lookupMessages = nil;
    for (NSDictionary *snap in snaps) {
        if (![snap isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *rich = [snap mutableCopy];
        id cid = rich[@"cid"];
        if (![cid respondsToSelector:@selector(longLongValue)] || [cid longLongValue] == 0) {
            id found = sm_plistId(sm_call(chatRef, "chatId"));
            if (found) rich[@"cid"] = found;
        }
        if (![rich[@"cpk"] isKindOfClass:[NSString class]]) {
            id cpk = sm_call(chatRef, "primaryKey");
            if ([cpk isKindOfClass:[NSString class]] && [(NSString *)cpk length]) rich[@"cpk"] = cpk;
        }
        sm_rememberSnapshot(rich);
    }
    for (id message in messages) {
        sm_prefixDeletedMark(message);
        sm_writeMarkedMessage(connection, message);
    }
    if (snaps.count || messages.count) sm_refreshDeletedLooks();
}

static BOOL sm_sameChat(NSDictionary *rec, id sample) {
    id cpk = sm_call(sample, "chatPrimaryKey");
    if ([cpk isKindOfClass:[NSString class]] && [rec[@"cpk"] isKindOfClass:[NSString class]] && [cpk isEqual:rec[@"cpk"]]) return YES;
    id cid = sm_call(sample, "chatId");
    if (rec[@"cid"] && cid && [cid respondsToSelector:@selector(longLongValue)]) {
        long long left = [rec[@"cid"] longLongValue];
        long long right = [cid longLongValue];
        if (left && left == right) return YES;
    }
    return NO;
}

static NSString *sm_msgKey(id message) {
    id pk = sm_call(message, "primaryKey");
    if ([pk isKindOfClass:[NSString class]] && [pk length]) return pk;
    id sid = sm_call(message, "serverId");
    if ([sid respondsToSelector:@selector(longLongValue)]) {
        long long value = [sid longLongValue];
        if (value) return [NSString stringWithFormat:@"sid:%lld", value];
    }
    return nil;
}

static id sm_makeMessage(NSDictionary *rec) {
    Class messageClass = objc_getClass("OKMMessage");
    Class textClass = objc_getClass("OKMMessageText");
    if (!messageClass) return nil;
    NSString *pk = [rec[@"pk"] isKindOfClass:[NSString class]] ? rec[@"pk"] : nil;
    id message = nil;
    if (pk.length && [messageClass instancesRespondToSelector:@selector(initWithPrimaryKey:)]) {
        id allocated = ((id (*)(id, SEL))objc_msgSend)(messageClass, @selector(alloc));
        message = ((id (*)(id, SEL, id))objc_msgSend)(allocated, @selector(initWithPrimaryKey:), pk);
    } else {
        message = ((id (*)(id, SEL))objc_msgSend)(messageClass, @selector(new));
    }
    if (!message) return nil;
    NSString *text = [rec[@"text"] isKindOfClass:[NSString class]] ? rec[@"text"] : nil;
    if (text.length && textClass) {
        NSString *visible = sm_stripDeletedMark(text);
        id allocated = ((id (*)(id, SEL))objc_msgSend)(textClass, @selector(alloc));
        id messageText = nil;
        if ([textClass instancesRespondToSelector:@selector(initWithText:)]) {
            messageText = ((id (*)(id, SEL, id))objc_msgSend)(allocated, @selector(initWithText:), visible);
        } else if ([textClass instancesRespondToSelector:@selector(initWithText:elements:)]) {
            messageText = ((id (*)(id, SEL, id, id))objc_msgSend)(allocated, @selector(initWithText:elements:), visible, nil);
        }
        if (messageText && [message respondsToSelector:@selector(setMessageText:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(message, @selector(setMessageText:), messageText);
        }
    }
    if (rec[@"sid"] && [message respondsToSelector:@selector(setServerId:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(message, @selector(setServerId:), rec[@"sid"]);
    }
    if (rec[@"cid"] && [message respondsToSelector:@selector(setChatId:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(message, @selector(setChatId:), rec[@"cid"]);
    }
    if (rec[@"cpk"] && [message respondsToSelector:@selector(setChatPrimaryKey:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(message, @selector(setChatPrimaryKey:), rec[@"cpk"]);
    }
    if (rec[@"sender"] && [message respondsToSelector:@selector(setSenderId:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(message, @selector(setSenderId:), rec[@"sender"]);
    }
    long long ts = [rec[@"ts"] longLongValue];
    if (ts && [message respondsToSelector:@selector(setTimestampAsInt:)]) {
        ((void (*)(id, SEL, long long))objc_msgSend)(message, @selector(setTimestampAsInt:), ts);
    }
    if ([message respondsToSelector:@selector(setStatus:)]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(message, @selector(setStatus:), 0);
    }
    if (rec[@"my"] && [message respondsToSelector:@selector(setMy:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(message, @selector(setMy:), [rec[@"my"] boolValue]);
    }
    return message;
}

static id sm_mergeKeptInto(id page, id messages) {
    if (!keepDeleted()) return messages;
    NSArray *current = [messages isKindOfClass:[NSArray class]] ? messages : nil;
    if (current.count == 0) return messages;
    sm_loadDeletedBodies();
    [smDeletedLock lock];
    NSArray *recs = [smKept copy];
    [smDeletedLock unlock];
    if (recs.count == 0) return messages;
    id sample = current.firstObject;
    long long minTs = LLONG_MAX;
    long long maxTs = LLONG_MIN;
    NSMutableSet *seen = [NSMutableSet set];
    for (id message in current) {
        NSString *key = sm_msgKey(message);
        if (key) [seen addObject:key];
        if (sm_isKeptKey(sm_call(message, "primaryKey")) || sm_isKeptServerId(sm_call(message, "serverId"))) {
            sm_prefixDeletedMark(message);
        }
        long long ts = sm_callLL(message, "timestampAsInt");
        if (ts < minTs) minTs = ts;
        if (ts > maxTs) maxTs = ts;
    }
    if ([page respondsToSelector:@selector(earliestMessageTimestamp)]) {
        @try {
            unsigned long long early = ((unsigned long long (*)(id, SEL))objc_msgSend)(page, @selector(earliestMessageTimestamp));
            if (early && (minTs == LLONG_MAX || (long long)early < minTs)) minTs = (long long)early;
        } @catch (__unused NSException *exception) {
        }
    }
    if ([page respondsToSelector:@selector(latestMessageTimestamp)]) {
        @try {
            unsigned long long late = ((unsigned long long (*)(id, SEL))objc_msgSend)(page, @selector(latestMessageTimestamp));
            if (late && (maxTs == LLONG_MIN || (long long)late > maxTs)) maxTs = (long long)late;
        } @catch (__unused NSException *exception) {
        }
    }
    BOOL lastPage = NO;
    if ([page respondsToSelector:@selector(isLastPage)]) {
        lastPage = ((BOOL (*)(id, SEL))objc_msgSend)(page, @selector(isLastPage));
    }
    NSMutableArray *extra = [NSMutableArray array];
    for (NSDictionary *rec in recs) {
        if (![rec isKindOfClass:[NSDictionary class]] || !sm_sameChat(rec, sample)) continue;
        NSString *pk = [rec[@"pk"] isKindOfClass:[NSString class]] ? rec[@"pk"] : nil;
        long long sid = [rec[@"sid"] longLongValue];
        if (pk.length && [seen containsObject:pk]) continue;
        if (sid && [seen containsObject:[NSString stringWithFormat:@"sid:%lld", sid]]) continue;
        long long ts = [rec[@"ts"] longLongValue];
        BOOL inRange = ts && minTs != LLONG_MAX && ts >= minTs && ts <= maxTs;
        BOOL tail = lastPage && ts && (maxTs == LLONG_MIN || ts > maxTs);
        if (!inRange && !tail) continue;
        id made = sm_makeMessage(rec);
        if (!made) continue;
        [extra addObject:made];
        if (pk.length) [seen addObject:pk];
        if (sid) [seen addObject:[NSString stringWithFormat:@"sid:%lld", sid]];
    }
    if (extra.count == 0) return messages;
    NSMutableArray *all = [current mutableCopy];
    [all addObjectsFromArray:extra];
    [all sortUsingComparator:^NSComparisonResult(id a, id b) {
        long long left = sm_callLL(a, "timestampAsInt");
        long long right = sm_callLL(b, "timestampAsInt");
        if (left < right) return NSOrderedAscending;
        if (left > right) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return all;
}

static void sm_noteHistoryPage(id value) {
    if (!keepDeleted() || !value || g_inMerge) return;
    const char *name = class_getName(object_getClass(value));
    if (!name || !strstr(name, "HistoryPage")) return;
    if (![value respondsToSelector:@selector(messages)] || ![value respondsToSelector:@selector(setMessages:)]) return;
    id current = ((id (*)(id, SEL))objc_msgSend)(value, @selector(messages));
    g_inMerge = YES;
    id merged = sm_mergeKeptInto(value, current);
    g_inMerge = NO;
    if (merged && merged != current) {
        g_inMerge = YES;
        ((void (*)(id, SEL, id))objc_msgSend)(value, @selector(setMessages:), merged);
        g_inMerge = NO;
    }
}

static NSString *sm_stringFromText(id value) {
    if (!value || value == (id)kCFNull || [value isKindOfClass:[NSNumber class]]) return nil;
    if ([value isKindOfClass:[NSString class]]) return [(NSString *)value length] ? value : nil;
    if ([value isKindOfClass:[NSAttributedString class]]) {
        NSString *string = ((NSAttributedString *)value).string;
        return string.length ? string : nil;
    }
    NSString *text = nil;
    sm_textIvar(value, &text);
    if (text.length) return text;
    if ([value respondsToSelector:@selector(text)]) {
        id inner = ((id (*)(id, SEL))objc_msgSend)(value, @selector(text));
        if ([inner isKindOfClass:[NSString class]] && [(NSString *)inner length]) return inner;
    }
    return nil;
}

static NSString *sm_messageBody(id message) {
    if (!message || [message isKindOfClass:[NSNumber class]]) return nil;
    NSString *direct = sm_stringFromText(message);
    if (direct.length && [message isKindOfClass:[NSString class]]) return direct;
    if ([message respondsToSelector:@selector(messageText)]) {
        NSString *text = sm_stringFromText(((id (*)(id, SEL))objc_msgSend)(message, @selector(messageText)));
        if (text.length) return text;
    }
    if ([message respondsToSelector:@selector(shownText)]) {
        NSString *text = sm_stringFromText(((id (*)(id, SEL))objc_msgSend)(message, @selector(shownText)));
        if (text.length) return text;
    }
    if ([message respondsToSelector:@selector(shownMessageText)]) {
        NSString *text = sm_stringFromText(((id (*)(id, SEL))objc_msgSend)(message, @selector(shownMessageText)));
        if (text.length) return text;
    }
    if ([message respondsToSelector:@selector(messageBody)]) {
        NSString *text = sm_stringFromText(((id (*)(id, SEL))objc_msgSend)(message, @selector(messageBody)));
        if (text.length) return text;
    }
    return direct;
}

static NSString *sm_viewText(UIView *view) {
    if (view.tag == kDeletedBadgeTag) return nil;
    if ([view isKindOfClass:[UILabel class]]) return ((UILabel *)view).text;
    if ([view isKindOfClass:[UITextView class]]) return ((UITextView *)view).text;
    if ([view respondsToSelector:@selector(attributedText)]) {
        id attr = ((id (*)(id, SEL))objc_msgSend)(view, @selector(attributedText));
        if ([attr isKindOfClass:[NSAttributedString class]]) {
            NSString *string = ((NSAttributedString *)attr).string;
            if (string.length) return string;
        }
    }
    if ([view respondsToSelector:@selector(text)]) {
        id text = ((id (*)(id, SEL))objc_msgSend)(view, @selector(text));
        if ([text isKindOfClass:[NSString class]] && [text length]) return text;
    }
    const char *name = class_getName(object_getClass(view));
    if (name && (strstr(name, "Text") || strstr(name, "Label") || strstr(name, "Message"))) {
        NSString *ivarText = nil;
        sm_textIvar(view, &ivarText);
        if (ivarText.length) return ivarText;
    }
    return nil;
}

static BOOL sm_treeHasDeletedText(UIView *view) {
    if (sm_isDeletedBody(sm_viewText(view))) return YES;
    if (view.tag != kDeletedBadgeTag && sm_isDeletedBody(view.accessibilityLabel)) return YES;
    for (UIView *subview in view.subviews) {
        if (sm_treeHasDeletedText(subview)) return YES;
    }
    return NO;
}

static BOOL sm_treeHasMark(UIView *view) {
    NSString *text = sm_viewText(view);
    if (text.length && [text rangeOfString:@"❌"].location != NSNotFound) return YES;
    for (UIView *subview in view.subviews) {
        if (subview.tag == kDeletedBadgeTag) continue;
        if (sm_treeHasMark(subview)) return YES;
    }
    return NO;
}

static BOOL sm_isHistoryMessageCell(UIView *view) {
    const char *name = class_getName(object_getClass(view));
    if (name && (strstr(name, "MessageCell") || strstr(name, "WidgetMessage"))) return YES;
    return [view isKindOfClass:[UICollectionViewCell class]] && name && strstr(name, "Bubble");
}

static id sm_boundMessage(UIView *view) {
    if (!view) return nil;
    Class cls = object_getClass(view);
    while (cls && cls != [UIView class] && cls != [NSObject class]) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; ivars && i < count; i++) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!type || type[0] != '@') continue;
            id value = nil;
            @try {
                value = object_getIvar(view, ivars[i]);
            } @catch (__unused NSException *exception) {
                value = nil;
            }
            if (smMessageClass && [value isKindOfClass:smMessageClass]) {
                free(ivars);
                return value;
            }
        }
        free(ivars);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static BOOL sm_looksLikeTime(NSString *text) {
    if (text.length < 4 || text.length > 24) return NO;
    if ([text rangeOfString:@"❌"].location != NSNotFound) return NO;
    NSRange colon = [text rangeOfString:@":"];
    return colon.location != NSNotFound && colon.location > 0;
}

static UILabel *sm_timeLabel(UIView *view) {
    UILabel *found = nil;
    if ([view isKindOfClass:[UILabel class]] && view.tag != kDeletedBadgeTag && sm_looksLikeTime(((UILabel *)view).text)) {
        found = (UILabel *)view;
    }
    for (UIView *subview in view.subviews) {
        if (subview.tag == kDeletedBadgeTag) continue;
        UILabel *inner = sm_timeLabel(subview);
        if (!inner) continue;
        if (!found || CGRectGetMaxY(inner.frame) >= CGRectGetMaxY(found.frame)) found = inner;
    }
    return found;
}

static BOOL sm_cellIsDeleted(UIView *cell) {
    if (!keepDeleted()) return NO;
    if (sm_treeHasDeletedText(cell)) return YES;
    id message = sm_boundMessage(cell);
    if (!message) {
        for (UIView *subview in cell.subviews) {
            message = sm_boundMessage(subview);
            if (message) break;
        }
    }
    if (!message) return NO;
    if (sm_isKeptKey(sm_call(message, "primaryKey"))) return YES;
    if (sm_isKeptServerId(sm_call(message, "serverId"))) return YES;
    return sm_isDeletedBody(sm_messageBody(message));
}

static UIView *sm_messageBubble(UIView *cell) {
    Class cls = object_getClass(cell);
    Ivar ivar = NULL;
    while (cls && !ivar) {
        ivar = class_getInstanceVariable(cls, "bubbleView");
        cls = class_getSuperclass(cls);
    }
    if (ivar) {
        id value = object_getIvar(cell, ivar);
        if ([value isKindOfClass:[UIView class]] && ((UIView *)value).bounds.size.width > 8) return value;
    }
    UIView *best = nil;
    CGFloat bestArea = 0;
    for (UIView *subview in cell.subviews) {
        if (subview.tag == kDeletedBadgeTag || subview.hidden) continue;
        CGFloat area = subview.bounds.size.width * subview.bounds.size.height;
        if (area > bestArea) {
            best = subview;
            bestArea = area;
        }
    }
    return best;
}

static BOOL sm_inHistoryList(UIView *view) {
    for (UIView *cursor = view; cursor; cursor = cursor.superview) {
        const char *name = class_getName(object_getClass(cursor));
        if (name && strstr(name, "HistoryCollection")) return YES;
    }
    return NO;
}

static BOOL sm_isTopHistoryCell(UIView *view) {
    BOOL candidate = sm_isHistoryMessageCell(view) || ([view isKindOfClass:[UICollectionViewCell class]] && sm_inHistoryList(view));
    if (!candidate) return NO;
    for (UIView *cursor = view.superview; cursor; cursor = cursor.superview) {
        if (sm_isHistoryMessageCell(cursor)) return NO;
        if ([cursor isKindOfClass:[UICollectionViewCell class]] && sm_inHistoryList(cursor)) return NO;
    }
    return YES;
}

static void sm_stripVisibleMark(UIView *view) {
    if (view.tag == kDeletedBadgeTag) return;
    NSString *text = nil;
    if ([view isKindOfClass:[UILabel class]]) text = ((UILabel *)view).text;
    else if ([view isKindOfClass:[UITextView class]]) text = ((UITextView *)view).text;
    if (text.length && [text rangeOfString:@"❌"].location != NSNotFound) {
        NSString *clean = sm_stripDeletedMark(text);
        if (![clean isEqualToString:text]) {
            if ([view isKindOfClass:[UILabel class]]) ((UILabel *)view).text = clean;
            else ((UITextView *)view).text = clean;
        }
    }
    for (UIView *subview in view.subviews) sm_stripVisibleMark(subview);
}

static void sm_updateDeletedCell(UIView *cell) {
    if (!sm_isTopHistoryCell(cell)) return;
    static char smTrashBusyKey;
    if (objc_getAssociatedObject(cell, &smTrashBusyKey)) return;
    objc_setAssociatedObject(cell, &smTrashBusyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL deleted = sm_cellIsDeleted(cell);
    UIView *bubble = sm_messageBubble(cell);
    UIView *badge = [cell viewWithTag:kDeletedBadgeTag];
    if (!deleted) {
        if (badge) [badge removeFromSuperview];
        if (bubble && bubble.alpha < 0.99) bubble.alpha = 1;
        objc_setAssociatedObject(cell, &smTrashBusyKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }
    if (bubble && bubble.alpha < 0.99) bubble.alpha = 1;
    sm_stripVisibleMark(cell);
    UIImageView *icon = [badge isKindOfClass:[UIImageView class]] ? (UIImageView *)badge : nil;
    if (!icon) {
        [badge removeFromSuperview];
        icon = [[UIImageView alloc] init];
        icon.tag = kDeletedBadgeTag;
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.userInteractionEnabled = NO;
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold];
        icon.image = [[UIImage systemImageNamed:@"trash" withConfiguration:config] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        icon.tintColor = [UIColor colorWithRed:1 green:0.23 blue:0.19 alpha:1];
        [cell addSubview:icon];
    } else if (icon.superview != cell) {
        [cell addSubview:icon];
    }
    CGFloat side = 12;
    CGRect bubbleFrame = bubble ? [bubble convertRect:bubble.bounds toView:cell] : cell.bounds;
    CGFloat x = CGRectGetMaxX(bubbleFrame) + 2;
    CGFloat y = CGRectGetMaxY(bubbleFrame) - side - 4;
    UILabel *time = sm_timeLabel(cell);
    if (time) {
        CGRect timeFrame = [time convertRect:time.bounds toView:cell];
        x = CGRectGetMaxX(timeFrame) + 6;
        y = CGRectGetMidY(timeFrame) - side / 2.0;
    }
    CGFloat maxX = cell.bounds.size.width - side - 1;
    if (x > maxX) x = maxX;
    if (x < 1) x = 1;
    if (y < 1) y = 1;
    icon.frame = CGRectMake(x, y, side, side);
    [cell bringSubviewToFront:icon];
    objc_setAssociatedObject(cell, &smTrashBusyKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void sm_markDeletedTree(UIView *view) {
    if (sm_isHistoryMessageCell(view)) {
        sm_updateDeletedCell(view);
        return;
    }
    for (UIView *subview in view.subviews) sm_markDeletedTree(subview);
}

static void sm_refreshDeletedLooks(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in allWindows()) sm_markDeletedTree(window);
    });
}

static IMP orig_setMessageText;

static NSString *const smEditMarker = @"\n—— было ——\n";

static NSString *sm_joinVersions(NSArray<NSString *> *parts) {
    NSMutableArray<NSString *> *unique = [NSMutableArray array];
    for (NSString *part in parts) {
        if (!part.length || [unique containsObject:part]) continue;
        [unique addObject:part];
    }
    return [unique componentsJoinedByString:smEditMarker];
}

static void swizzled_setMessageText(id self, SEL _cmd, id newText) {
    if ((keepEdits() || keepDeleted()) && newText && [self respondsToSelector:@selector(messageText)]) {
        id oldText = ((id (*)(id, SEL))objc_msgSend)(self, @selector(messageText));
        NSString *oldString = nil;
        NSString *newString = nil;
        sm_textIvar(oldText, &oldString);
        Ivar ivar = sm_textIvar(newText, &newString);
        if (keepDeleted() && oldString.length && newString.length == 0) return;
        if (keepEdits() && oldString.length && newString.length && [newString rangeOfString:smEditMarker].location == NSNotFound) {
            NSArray<NSString *> *oldParts = [oldString componentsSeparatedByString:smEditMarker];
            if ([oldParts containsObject:newString]) {
                NSString *collapsed = sm_joinVersions(oldParts);
                if ([collapsed isEqualToString:oldString]) return;
                if (ivar) object_setIvar(newText, ivar, collapsed);
            } else if (![oldString isEqualToString:newString]) {
                NSMutableArray<NSString *> *parts = [NSMutableArray array];
                for (NSString *part in oldParts) {
                    if (part.length && ![part isEqualToString:newString]) [parts addObject:part];
                }
                [parts addObject:newString];
                if (ivar) object_setIvar(newText, ivar, sm_joinVersions(parts));
            }
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

static AVAudioPlayer *smSilentPlayer;
static NSTimer *smAudioTimer;
static BOOL smAudioOwned;
static IMP orig_keepSocket;
static IMP orig_disconnectIfNeeded;
static IMP orig_messageReceived;

static NSData *sm_silentWav(void) {
    const uint32_t rate = 16000;
    const uint32_t frames = rate;
    const uint16_t channels = 1;
    const uint16_t bits = 16;
    uint32_t dataSize = frames * channels * (bits / 8);
    uint32_t riffSize = 36 + dataSize;
    uint32_t fmtSize = 16;
    uint16_t audioFormat = 1;
    uint32_t byteRate = rate * channels * (bits / 8);
    uint16_t blockAlign = channels * (bits / 8);
    NSMutableData *data = [NSMutableData dataWithLength:44 + dataSize];
    uint8_t *bytes = data.mutableBytes;
    memcpy(bytes, "RIFF", 4);
    memcpy(bytes + 4, &riffSize, 4);
    memcpy(bytes + 8, "WAVEfmt ", 8);
    memcpy(bytes + 16, &fmtSize, 4);
    memcpy(bytes + 20, &audioFormat, 2);
    memcpy(bytes + 22, &channels, 2);
    memcpy(bytes + 24, &rate, 4);
    memcpy(bytes + 28, &byteRate, 4);
    memcpy(bytes + 32, &blockAlign, 2);
    memcpy(bytes + 34, &bits, 2);
    memcpy(bytes + 36, "data", 4);
    memcpy(bytes + 40, &dataSize, 4);
    int16_t *samples = (int16_t *)(bytes + 44);
    for (uint32_t i = 0; i < frames; i++) samples[i] = (i & 32) ? 8 : -8;
    return data;
}

static BOOL sm_audioBusy(void) {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSString *category = session.category;
    return [category isEqualToString:AVAudioSessionCategoryPlayAndRecord] || [category isEqualToString:AVAudioSessionCategoryRecord];
}

static void sm_startSilentAudio(void) {
    if (!bgNotify() || sm_audioBusy()) return;
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&error];
    [session setActive:YES error:&error];
    if (!smSilentPlayer) {
        smSilentPlayer = [[AVAudioPlayer alloc] initWithData:sm_silentWav() error:&error];
        smSilentPlayer.numberOfLoops = -1;
        smSilentPlayer.volume = 1;
    }
    if (smSilentPlayer && !smSilentPlayer.playing) [smSilentPlayer play];
    smAudioOwned = smSilentPlayer.playing;
}

static void sm_stopSilentAudio(void) {
    [smSilentPlayer stop];
    if (!smAudioOwned) return;
    smAudioOwned = NO;
    if (sm_audioBusy()) return;
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
}

static void sm_startLocation(void);

static void sm_ensureAudioTimer(void) {
    if (smAudioTimer) return;
    smAudioTimer = [NSTimer scheduledTimerWithTimeInterval:15 repeats:YES block:^(__unused NSTimer *timer) {
        if (!bgNotify()) return;
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) return;
        sm_startSilentAudio();
        sm_startLocation();
    }];
}

static BOOL swizzled_keepSocket(id self, SEL _cmd) {
    if (bgNotify()) return YES;
    return orig_keepSocket ? ((BOOL (*)(id, SEL))orig_keepSocket)(self, _cmd) : NO;
}

static void swizzled_disconnectIfNeeded(id self, SEL _cmd) {
    if (bgNotify() && UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if (orig_disconnectIfNeeded) ((void (*)(id, SEL))orig_disconnectIfNeeded)(self, _cmd);
}

static NSString *sm_noteTitle(id chat) {
    const char *names[] = {"localTitle", "title", "displayTitle", "chatTitle", "name", NULL};
    for (int i = 0; names[i]; i++) {
        id value = sm_call(chat, names[i]);
        if ([value isKindOfClass:[NSString class]] && [value length]) return value;
    }
    return @"MAX";
}

static void sm_deliver(NSString *title, NSString *body) {
    if (!bgNotify()) return;
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) return;
    if (body.length == 0) body = @"Новое сообщение";
    if (title.length == 0) title = @"MAX";
    NSString *key = [title stringByAppendingString:body];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    static NSString *lastKey;
    static NSTimeInterval lastTime;
    if (lastKey && [lastKey isEqualToString:key] && now - lastTime < 3) return;
    lastKey = key;
    lastTime = now;
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title;
    content.body = body;
    content.sound = [UNNotificationSound defaultSound];
    NSString *identifier = [NSString stringWithFormat:@"sm-%llu", (unsigned long long)(now * 1000)];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
}

static id smChatService;

static id sm_chatServiceFrom(id owner) {
    id service = sm_call(owner, "chatService");
    if (!service && [owner respondsToSelector:sel_registerName("cachedChatWithId:")]) service = owner;
    if (service) smChatService = service;
    return service ?: smChatService;
}

static id g_chatLookupId;
static id g_chatLookupChat;

static void sm_chat_lookup_invoke(void *block, id transaction) {
    (void)block;
    SEL sel = sel_registerName("okm_chatForChatId:");
    if (![transaction respondsToSelector:sel]) return;
    @try {
        g_chatLookupChat = ((id (*)(id, SEL, id))objc_msgSend)(transaction, sel, g_chatLookupId);
    } @catch (__unused NSException *exception) {
        g_chatLookupChat = nil;
    }
}

static id sm_chatLookupBlock(void) {
    static SMBlockLiteral block;
    static struct { unsigned long reserved; unsigned long size; const char *signature; const char *layout; } desc;
    static dispatch_once_t once;
    static BOOL ready;
    dispatch_once(&once, ^{
        void *isa = dlsym(RTLD_DEFAULT, "_NSConcreteGlobalBlock");
        if (!isa) return;
        desc.size = sizeof(block);
        desc.signature = "v16@?0@8";
        desc.layout = "\0";
        block.isa = isa;
        block.flags = (1 << 28) | (1 << 30);
        block.invoke = (void *)sm_chat_lookup_invoke;
        block.descriptor = &desc;
        ready = YES;
    });
    return ready ? (__bridge id)&block : nil;
}

static BOOL sm_isChatObject(id obj) {
    const char *name = obj ? class_getName(object_getClass(obj)) : NULL;
    return name && strcmp(name, "OKMChat") == 0;
}

static id sm_cachedChat(id service, id chatId) {
    if (!service || !chatId) return nil;
    id connection = sm_call(service, "readConnection");
    if (!connection) connection = sm_call(service, "dbConnection");
    id block = sm_chatLookupBlock();
    if (!connection || !block || ![connection respondsToSelector:@selector(readWithBlock:)]) return nil;
    g_chatLookupId = chatId;
    g_chatLookupChat = nil;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(connection, @selector(readWithBlock:), block);
    } @catch (__unused NSException *exception) {
        g_chatLookupChat = nil;
    }
    id chat = g_chatLookupChat;
    g_chatLookupId = nil;
    g_chatLookupChat = nil;
    return sm_isChatObject(chat) ? chat : nil;
}

static BOOL sm_pkMuted(id service, id pk) {
    if (!pk || !service) return NO;
    id host = sm_call(service, "messengerConfig");
    SEL lookup = sel_registerName("chatConfigForChatPk:");
    if (!host || ![host respondsToSelector:lookup]) return NO;
    id config = nil;
    @try {
        config = ((id (*)(id, SEL, id))objc_msgSend)(host, lookup, pk);
    } @catch (__unused NSException *exception) {
        return NO;
    }
    SEL disturb = sel_registerName("isDontDisturb");
    return config && [config respondsToSelector:disturb] && ((BOOL (*)(id, SEL))objc_msgSend)(config, disturb);
}

static BOOL sm_chatMuted(id service, id chat) {
    return sm_pkMuted(service, sm_call(chat, "primaryKey"));
}

static void sm_postIncoming(id note, id owner) {
    if (!bgNotify() || !note) return;
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) return;
    id message = sm_call(note, "message");
    if (!message) message = note;
    if ([message respondsToSelector:@selector(my)] && ((BOOL (*)(id, SEL))objc_msgSend)(message, @selector(my))) return;
    id service = sm_chatServiceFrom(owner);
    id chatId = sm_call(note, "chatId");
    if (!chatId) chatId = sm_call(message, "chatId");
    id chat = sm_call(note, "chat");
    if (!sm_isChatObject(chat)) chat = sm_call(message, "chat");
    if (!sm_isChatObject(chat)) chat = nil;
    if (!chatId) chatId = sm_call(chat, "chatId");
    if (!chat) chat = sm_cachedChat(service, chatId);
    if (sm_chatMuted(service, chat)) return;
    if (sm_pkMuted(service, sm_call(message, "chatPrimaryKey"))) return;
    NSString *body = sm_messageBody(message);
    if ([body containsString:@"\n—— было ——\n"]) body = [[body componentsSeparatedByString:@"\n—— было ——\n"] lastObject];
    body = [body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (body.length > 180) body = [[body substringToIndex:180] stringByAppendingString:@"…"];
    id contact = sm_call(message, "senderContact");
    NSString *sender = sm_call(contact, "fullName");
    if (![sender isKindOfClass:[NSString class]] || sender.length == 0) sender = sm_call(contact, "name");
    NSString *title = sm_noteTitle(chat);
    if ([sender isKindOfClass:[NSString class]] && sender.length && ![sender isEqualToString:title]) {
        body = [NSString stringWithFormat:@"%@: %@", sender, body];
    }
    sm_deliver(title, body);
}

static IMP orig_showBanner;
static void swizzled_showBanner(id self, SEL _cmd, id banner, BOOL suppress) {
    if (orig_showBanner) ((void (*)(id, SEL, id, BOOL))orig_showBanner)(self, _cmd, banner, suppress);
}

static void swizzled_messageReceived(id self, SEL _cmd, id note) {
    if (orig_messageReceived) ((void (*)(id, SEL, id))orig_messageReceived)(self, _cmd, note);
    sm_postIncoming(note, self);
}

static CLLocationManager *smLoc;
static id smLocDelegate;
static BOOL smLocRunning;

static void sm_startLocation(void);

@interface SMBgLocator : NSObject <CLLocationManagerDelegate>
@end

@implementation SMBgLocator
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    (void)manager;
    if (bgNotify()) sm_startLocation();
}
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    (void)manager;
    (void)locations;
}
@end

static void sm_startLocation(void) {
    if (!bgNotify()) return;
    if (!smLoc) {
        smLocDelegate = [SMBgLocator new];
        smLoc = [[CLLocationManager alloc] init];
        smLoc.delegate = smLocDelegate;
        smLoc.desiredAccuracy = kCLLocationAccuracyReduced;
        smLoc.distanceFilter = kCLDistanceFilterNone;
        smLoc.pausesLocationUpdatesAutomatically = NO;
    }
    CLAuthorizationStatus status;
    if ([smLoc respondsToSelector:@selector(authorizationStatus)]) status = smLoc.authorizationStatus;
    else status = [CLLocationManager authorizationStatus];
    if (status == kCLAuthorizationStatusNotDetermined) {
        static BOOL asked;
        if (!asked) {
            asked = YES;
            [smLoc requestAlwaysAuthorization];
        }
        return;
    }
    if (status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted) return;
    if (smLocRunning) return;
    @try {
        smLoc.allowsBackgroundLocationUpdates = YES;
        [smLoc startUpdatingLocation];
        smLocRunning = YES;
    } @catch (__unused NSException *exception) {
        smLocRunning = NO;
    }
}

static void sm_stopLocation(void) {
    [smLoc stopUpdatingLocation];
    smLocRunning = NO;
}

static void sm_warnIfNotificationsDenied(void) {
    [[UNUserNotificationCenter currentNotificationCenter] getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        if (settings.authorizationStatus != UNAuthorizationStatusDenied) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *from = topController();
            if (!from) return;
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Нет доступа к уведомлениям"
                                                                           message:@"Включи уведомления для MAX в Настройках iPhone, иначе баннер не появится."
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Понятно" style:UIAlertActionStyleDefault handler:nil]];
            [from presentViewController:alert animated:YES completion:nil];
        });
    }];
}

static void sm_bgNotifyChanged(BOOL on) {
    if (!on) {
        sm_stopSilentAudio();
        sm_stopLocation();
        return;
    }
    UNAuthorizationOptions options = UNAuthorizationOptionAlert | UNAuthorizationOptionSound;
    [[UNUserNotificationCenter currentNotificationCenter] requestAuthorizationWithOptions:options completionHandler:^(__unused BOOL granted, __unused NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ sm_warnIfNotificationsDenied(); });
    }];
    sm_ensureAudioTimer();
    sm_startLocation();
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) sm_startSilentAudio();
}

static void hookBgNotify(void) {
    sm_hook_own(objc_getClass("OKMAppStateManager"), "keepSocketInBackground", (IMP)swizzled_keepSocket, &orig_keepSocket);
    sm_hook_own(objc_getClass("OKMMessengerClient"), "disconnectIfNeeded", (IMP)swizzled_disconnectIfNeeded, &orig_disconnectIfNeeded);
    sm_hook_own(objc_getClass("OKMIncomingMessagesListener"), "_messageReceived:", (IMP)swizzled_messageReceived, &orig_messageReceived);
    sm_hook_own(objc_getClass("OKMInAppBannerPresenter"), "showNewMessageBanner:suppressToast:", (IMP)swizzled_showBanner, &orig_showBanner);
    static BOOL watching;
    if (watching) return;
    watching = YES;
    sm_ensureAudioTimer();
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        if (!bgNotify()) return;
        sm_startSilentAudio();
        sm_startLocation();
    }];
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        if (!bgNotify()) return;
        sm_startSilentAudio();
        sm_startLocation();
    }];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        sm_stopSilentAudio();
        sm_stopLocation();
    }];
    [center addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
        if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded && bgNotify() &&
            UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
            sm_startSilentAudio();
        }
    }];
    if (bgNotify()) sm_bgNotifyChanged(YES);
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
    hookBgNotify();
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
        hookKeepDeleted();
        scheduleRestyle();
    }];
    foregroundObserver = [center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        hookKeepDeleted();
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
    hookBgNotify();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        resolveAndHook();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        resolveAndHook();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        hookKeepDeleted();
        hookBgNotify();
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
