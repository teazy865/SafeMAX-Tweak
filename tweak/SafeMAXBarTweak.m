#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>

// SafeMAX bottom dock is OMUIKit.TabBar, not UITabBar.
// Never hide or fade existing subviews: that removes the icons.

static NSString *const kShowLabelsKey = @"SafeMAX_ShowLabels";
static NSString *const kFloatingKey = @"SafeMAX_FloatingDock";
static NSString *const kGlassKey = @"SafeMAX_LiquidGlass";
static NSString *const kOrderKey = @"SafeMAX_TabOrder";
static NSString *const kHiddenKey = @"SafeMAX_HiddenTabs";
static NSString *const kExtraKey = @"SafeMAX_ExtraTabs";
static NSString *const kFavoritesTitle = @"Избранное";

static const NSInteger kEntryTag = 0x5AF1;
static const NSInteger kPillTag = 0x5AF3;
static const NSInteger kExtraTag = 0x5AF4;
static const NSInteger kSelectTag = 0x5AF6;

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

static BOOL liquidGlass(void) {
    id obj = [[NSUserDefaults standardUserDefaults] objectForKey:kGlassKey];
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
        if (sub.tag == kPillTag || sub.tag == kSelectTag) continue;
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
        if (!view || view.tag == kPillTag || view.tag == kSelectTag || view.tag == kExtraTag || view.hidden || view.alpha < 0.05) return;
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

static NSMutableSet<NSString *> *hiddenTabs(void) {
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:kHiddenKey];
    return [NSMutableSet setWithArray:stored ?: @[]];
}

static void saveHidden(NSSet<NSString *> *set) {
    [[NSUserDefaults standardUserDefaults] setObject:set.allObjects forKey:kHiddenKey];
}

static NSMutableArray<UIView *> *visibleDockItems(UIView *bar) {
    NSSet *hidden = hiddenTabs();
    NSMutableArray<UIView *> *visible = [NSMutableArray array];
    for (UIView *item in tabItems(bar)) {
        NSString *title = titleOfItem(item);
        BOOL hide = title.length && [hidden containsObject:title];
        item.hidden = hide;
        item.alpha = hide ? 0 : 1;
        item.userInteractionEnabled = !hide;
        if (!hide) [visible addObject:item];
    }
    NSArray<NSString *> *order = savedOrder();
    if (order.count == 0) return visible;
    NSMutableArray<UIView *> *arranged = [NSMutableArray array];
    NSMutableSet *used = [NSMutableSet set];
    for (NSString *title in order) {
        for (UIView *item in visible) {
            if ([used containsObject:item]) continue;
            if ([titleOfItem(item) isEqualToString:title]) {
                [arranged addObject:item];
                [used addObject:item];
                break;
            }
        }
    }
    for (UIView *item in visible) {
        if (![used containsObject:item]) [arranged addObject:item];
    }
    return arranged;
}

static void layoutDockSlots(UIView *bar) {
    [[bar viewWithTag:kExtraTag] removeFromSuperview];
    NSArray<UIView *> *items = visibleDockItems(bar);
    if (items.count == 0) return;
    CGFloat side = floatingDock() ? 18 : 0;
    CGFloat width = MAX(1, bar.bounds.size.width - side * 2);
    CGFloat slot = width / items.count;
    for (NSUInteger i = 0; i < items.count; i++) {
        UIView *item = items[i];
        CGPoint center = item.center;
        center.x = side + slot * (i + 0.5);
        item.center = center;
    }
}

static UIVisualEffect *makeGlass(void);

static CGFloat accentScore(UIColor *color) {
    if (!color) return 0;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) return 0;
    return (b + r * 0.15) - g;
}

static UIView *selectedDockItem(NSArray<UIView *> *items) {
    UIView *best = items.firstObject;
    CGFloat bestScore = -100;
    for (UIView *item in items) {
        __block CGFloat score = 0;
        eachLabel(item, ^(UILabel *label) {
            score = MAX(score, accentScore(label.textColor));
        });
        if (score > bestScore) {
            bestScore = score;
            best = item;
        }
    }
    return best;
}

static void placeSelection(UIView *bar, UIView *forced, BOOL dragging) {
    NSArray<UIView *> *items = visibleDockItems(bar);
    if (items.count == 0) return;
    UIView *item = forced ?: selectedDockItem(items);
    if (!item) return;
    UIVisualEffectView *mark = (UIVisualEffectView *)[bar viewWithTag:kSelectTag];
    if (![mark isKindOfClass:[UIVisualEffectView class]]) {
        [mark removeFromSuperview];
        mark = [[UIVisualEffectView alloc] initWithEffect:nil];
        mark.tag = kSelectTag;
        mark.userInteractionEnabled = NO;
        mark.clipsToBounds = YES;
        [bar addSubview:mark];
    }
    UIView *pill = [bar viewWithTag:kPillTag];
    if (pill) [bar insertSubview:mark aboveSubview:pill];
    else [bar sendSubviewToBack:mark];

    CGRect host = pill ? pill.frame : CGRectInset(bar.bounds, 8, 4);
    CGRect itemFrame = [item convertRect:item.bounds toView:bar];
    CGFloat count = MAX(1, items.count);
    CGFloat slot = CGRectGetWidth(host) / count;
    CGFloat height = MAX(36, CGRectGetHeight(host) - 8);
    CGFloat width = MAX(height * 0.9, slot - 8);
    CGFloat x = CGRectGetMidX(itemFrame) - width / 2.0;
    CGFloat minX = CGRectGetMinX(host) + 4;
    CGFloat maxX = CGRectGetMaxX(host) - 4 - width;
    if (maxX < minX) maxX = minX;
    if (x < minX) x = minX;
    if (x > maxX) x = maxX;
    CGFloat y = CGRectGetMidY(host) - height / 2.0;
    CGRect frame = CGRectMake(x, y, width, height);
    BOOL glass = dragging && liquidGlass();
    void (^apply)(void) = ^{
        mark.frame = frame;
        mark.layer.cornerCurve = kCACornerCurveContinuous;
        if (glass) {
            mark.clipsToBounds = NO;
            mark.layer.cornerRadius = height / 2.0;
            mark.backgroundColor = [UIColor clearColor];
            mark.effect = makeGlass();
        } else {
            mark.clipsToBounds = YES;
            mark.layer.cornerRadius = MIN(26, height / 2.0);
            mark.effect = nil;
            BOOL dark = bar.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
            mark.backgroundColor = [UIColor colorWithWhite:dark ? 1 : 0 alpha:dark ? 0.16 : 0.08];
        }
    };
    if (dragging) {
        [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.4 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:apply completion:nil];
    } else {
        apply();
    }
}

@interface SMDragRelay : NSObject
@end

@implementation SMDragRelay

- (void)pressed:(UILongPressGestureRecognizer *)gesture {
    UIView *bar = gesture.view;
    if (![bar isKindOfClass:[UIView class]]) return;
    NSArray<UIView *> *items = visibleDockItems(bar);
    if (items.count == 0) return;
    CGPoint point = [gesture locationInView:bar];
    UIView *hit = items.firstObject;
    CGFloat best = CGFLOAT_MAX;
    for (UIView *item in items) {
        CGFloat distance = fabs(CGRectGetMidX([item convertRect:item.bounds toView:bar]) - point.x);
        if (distance < best) {
            best = distance;
            hit = item;
        }
    }
    BOOL dragging = gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged;
    placeSelection(bar, hit, dragging);
    if (dragging) {
        NSString *title = titleOfItem(hit);
        NSString *last = objc_getAssociatedObject(bar, "sm_dragTitle");
        if (title.length && ![title isEqualToString:last]) {
            objc_setAssociatedObject(bar, "sm_dragTitle", title, OBJC_ASSOCIATION_COPY_NONATOMIC);
            UIControl *control = [hit isKindOfClass:[UIControl class]] ? (UIControl *)hit : nil;
            UIView *cursor = hit;
            while (!control && cursor.superview && cursor.superview != bar) {
                cursor = cursor.superview;
                if ([cursor isKindOfClass:[UIControl class]]) control = (UIControl *)cursor;
            }
            [control sendActionsForControlEvents:UIControlEventTouchUpInside];
        }
    } else {
        objc_setAssociatedObject(bar, "sm_dragTitle", nil, OBJC_ASSOCIATION_ASSIGN);
    }
}

@end

static void installDrag(UIView *bar) {
    if (objc_getAssociatedObject(bar, "sm_drag")) return;
    SMDragRelay *relay = [SMDragRelay new];
    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc] initWithTarget:relay action:@selector(pressed:)];
    gesture.minimumPressDuration = 0.12;
    gesture.cancelsTouchesInView = NO;
    gesture.delaysTouchesBegan = NO;
    [bar addGestureRecognizer:gesture];
    objc_setAssociatedObject(bar, "sm_drag", relay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    layoutDockSlots(bar);

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
        [[bar viewWithTag:kSelectTag] removeFromSuperview];
        return;
    }

    installDrag(bar);
    CGRect glyphs = chromeBounds(bar);
    if (CGRectIsNull(glyphs)) {
        if (!objc_getAssociatedObject(bar, "sm_dragTitle")) placeSelection(bar, nil, NO);
        return;
    }
    CGFloat side = 18;
    CGFloat padY = showLabels() ? 9 : 11;
    CGFloat height = CGRectIsNull(glyphs) ? 54 : MAX(showLabels() ? 56 : 46, CGRectGetHeight(glyphs) + padY * 2);
    CGFloat y = CGRectIsNull(glyphs) ? 4 : CGRectGetMidY(glyphs) - height / 2.0;
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
    NSString *mode = [NSString stringWithFormat:@"%d-%ld", liquidGlass(), (long)bar.traitCollection.userInterfaceStyle];
    if (![objc_getAssociatedObject(glass, "sm_mode") isEqual:mode]) {
        objc_setAssociatedObject(glass, "sm_mode", mode, OBJC_ASSOCIATION_COPY_NONATOMIC);
        if (liquidGlass()) {
            glass.backgroundColor = [UIColor clearColor];
            glass.clipsToBounds = NO;
            glass.layer.cornerRadius = 0;
            glass.effect = makeGlass();
        } else {
            glass.effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
            glass.effect = nil;
            glass.clipsToBounds = YES;
            glass.layer.cornerRadius = height / 2.0;
            glass.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *trait) {
                return trait.userInterfaceStyle == UIUserInterfaceStyleDark
                    ? [UIColor colorWithWhite:0.07 alpha:0.94]
                    : [UIColor colorWithWhite:1 alpha:0.94];
            }];
        }
    }
    if (liquidGlass()) {
        glass.layer.cornerRadius = height / 2.0;
        glass.layer.cornerCurve = kCACornerCurveCircular;
    }
    [bar sendSubviewToBack:pill];
    installDrag(bar);
    if (!objc_getAssociatedObject(bar, "sm_dragTitle")) placeSelection(bar, nil, NO);
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

static void activateControl(UIView *view) {
    UIControl *control = [view isKindOfClass:[UIControl class]] ? (UIControl *)view : nil;
    UIView *cursor = view;
    while (!control && cursor.superview) {
        cursor = cursor.superview;
        if ([cursor isKindOfClass:[UIControl class]]) control = (UIControl *)cursor;
    }
    [control sendActionsForControlEvents:UIControlEventTouchUpInside];
}

@interface SMDockEntry : UIControl
@property (nonatomic, weak) UIViewController *owner;
@end

@interface SMDockEditor : UITableViewController
@property (nonatomic, strong) NSMutableArray<NSString *> *titles;
@property (nonatomic, strong) NSMutableArray<NSString *> *catalog;
@end

static void presentEditor(UIViewController *from);

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
    ((UILabel *)[self viewWithTag:2]).textColor = foreground;
    ((UIImageView *)[self viewWithTag:4]).tintColor = [UIColor tertiaryLabelColor];
    [self viewWithTag:1].frame = CGRectMake(16, (self.bounds.size.height - 24) / 2.0, 24, 24);
    [self viewWithTag:4].frame = CGRectMake(self.bounds.size.width - 28, (self.bounds.size.height - 14) / 2.0, 12, 14);
    [self viewWithTag:2].frame = CGRectMake(56, 0, self.bounds.size.width - 96, self.bounds.size.height);
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
    if (!self.catalog) self.catalog = [NSMutableArray array];
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
    styleAllBars();
}

- (void)switchChanged:(UISwitch *)sender {
    NSNumber *row = objc_getAssociatedObject(sender, "sm_row");
    if (row.integerValue == 0) {
        [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kShowLabelsKey];
    } else if (row.integerValue == 1) {
        [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kFloatingKey];
    } else {
        [[NSUserDefaults standardUserDefaults] setBool:sender.on forKey:kGlassKey];
    }
    styleAllBars();
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 3;
    if (section == 1) return self.titles.count;
    return self.catalog.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"Опции";
    if (section == 1) return @"В доке";
    return @"Добавить";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"Жидкое стекло включает оформление iOS 26 во всём приложении. Закройте MAX и откройте снова, чтобы оно применилось.";
    if (section == 1) return @"Минус убирает вкладку. Полоски справа меняют порядок. Оставшиеся иконки стоят симметрично.";
    return @"Нажмите вкладку, чтобы вернуть её в док.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"c"];
    cell.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *toggle = [cell.contentView viewWithTag:9];
    if (indexPath.section == 0) {
        NSString *title = @"Парящий док";
        BOOL on = floatingDock();
        if (indexPath.row == 0) {
            title = @"Текст под иконками";
            on = showLabels();
        } else if (indexPath.row == 2) {
            title = @"Жидкое стекло";
            on = liquidGlass();
        }
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
    } else if (indexPath.section == 1) {
        cell.textLabel.text = self.titles[indexPath.row];
        toggle.hidden = YES;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.text = self.catalog[indexPath.row];
        toggle.hidden = YES;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
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
    return indexPath.section == 1 && self.titles.count > 1 ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete || indexPath.section != 1) return;
    NSString *title = self.titles[indexPath.row];
    [self.titles removeObjectAtIndex:indexPath.row];
    NSMutableSet *hidden = hiddenTabs();
    [hidden addObject:title];
    saveHidden(hidden);
    if (![self.catalog containsObject:title]) [self.catalog addObject:title];
    saveOrder(self.titles);
    [tableView reloadData];
    styleAllBars();
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 2) return;
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *title = self.catalog[indexPath.row];
    [self.catalog removeObjectAtIndex:indexPath.row];
    [self.titles addObject:title];
    NSMutableSet *hidden = hiddenTabs();
    [hidden removeObject:title];
    saveHidden(hidden);
    saveOrder(self.titles);
    [tableView reloadData];
    styleAllBars();
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
    NSSet *hidden = hiddenTabs();
    NSMutableArray *pool = [NSMutableArray array];
    for (UIView *item in tabItems(locateBar())) {
        NSString *title = titleOfItem(item);
        if (title.length && ![pool containsObject:title] && ![title isEqualToString:kFavoritesTitle]) [pool addObject:title];
    }
    if (pool.count == 0) [pool addObjectsFromArray:@[@"Контакты", @"Звонки", @"Чаты", @"Настройки"]];
    NSMutableArray *titles = [NSMutableArray array];
    for (NSString *title in savedOrder()) {
        if ([pool containsObject:title] && ![hidden containsObject:title] && ![titles containsObject:title]) {
            [titles addObject:title];
        }
    }
    for (NSString *title in pool) {
        if (![hidden containsObject:title] && ![titles containsObject:title]) [titles addObject:title];
    }
    NSMutableArray *catalog = [NSMutableArray array];
    for (NSString *title in pool) {
        if ([hidden containsObject:title]) [catalog addObject:title];
    }
    SMDockEditor *editor = [[SMDockEditor alloc] init];
    editor.titles = titles;
    editor.catalog = catalog;
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

    CGFloat width = scroll.bounds.size.width;
    CGFloat side = 16;
    CGFloat height = 52;
    CGFloat y = scroll.contentSize.height + 14;
    entry.frame = CGRectMake(side, y, width - side * 2, height);

    CGFloat extra = height + 36;
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

    g_inSettings = NO;
}

static BOOL isDockView(UIView *view) {
    if (TabBarClass) return [view isKindOfClass:TabBarClass];
    return isBottomBar(view);
}

static IMP orig_trait;

static void swizzled_trait(id self, SEL _cmd, UITraitCollection *previous) {
    ((void (*)(id, SEL, UITraitCollection *))orig_trait)(self, _cmd, previous);
    if (![self isKindOfClass:[UIView class]]) return;
    UIView *view = self;
    if (!isDockView(view) && ![view isKindOfClass:[UIWindow class]]) return;
    if (previous.userInterfaceStyle == view.traitCollection.userInterfaceStyle) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        styleAllBars();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        styleAllBars();
    });
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

    Method trait = class_getInstanceMethod([UIView class], @selector(traitCollectionDidChange:));
    orig_trait = method_getImplementation(trait);
    method_setImplementation(trait, (IMP)swizzled_trait);
}

static IMP orig_infoDictionary;
static IMP orig_infoKey;

static BOOL g_inInfo;

static NSDictionary *swizzled_infoDictionary(id self, SEL _cmd) {
    NSDictionary *dict = ((NSDictionary *(*)(id, SEL))orig_infoDictionary)(self, _cmd);
    if (g_inInfo || self != [NSBundle mainBundle] || ![dict isKindOfClass:[NSDictionary class]]) return dict;
    g_inInfo = YES;
    BOOL glass = liquidGlass();
    g_inInfo = NO;
    NSMutableDictionary *copy = [dict mutableCopy];
    copy[@"UIDesignRequiresCompatibility"] = glass ? @NO : @YES;
    return copy;
}

static id swizzled_infoKey(id self, SEL _cmd, NSString *key) {
    if (!g_inInfo && self == [NSBundle mainBundle] && [key isEqualToString:@"UIDesignRequiresCompatibility"]) {
        g_inInfo = YES;
        BOOL glass = liquidGlass();
        g_inInfo = NO;
        return glass ? @NO : @YES;
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

__attribute__((constructor))
static void safeMAXDockInit(void) {
    hookLiquidGlassFlag();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        resolveAndHook();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        resolveAndHook();
    });
}
