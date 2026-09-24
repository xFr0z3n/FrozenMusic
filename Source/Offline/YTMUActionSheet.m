#import "YTMUActionSheet.h"
#import "YTMUOfflineUI.h"

@implementation YTMUSheetAction

+ (instancetype)actionWithTitle:(NSString *)title symbol:(NSString *)symbol handler:(void (^)(void))handler {
    YTMUSheetAction *action = [YTMUSheetAction new];
    action.title = title;
    action.symbol = symbol;
    action.handler = handler;
    return action;
}

@end

static UIColor *YTMUSheetBackground(void) {
    return YTMUIsOLED() ? [UIColor blackColor] : [UIColor colorWithRed:0.13 green:0.13 blue:0.13 alpha:1.0];
}

static UIImage *YTMUSheetIcon(NSString *symbol, CGFloat size) {
    if (!symbol.length)
        return nil;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightRegular];
    return [UIImage systemImageNamed:symbol withConfiguration:config];
}

@interface YTMUActionSheet () <UIGestureRecognizerDelegate>
@property (nonatomic, copy) NSString *sheetTitle;
@property (nonatomic, copy) NSString *sheetSubtitle;
@property (nonatomic, strong) NSMutableArray<YTMUSheetAction *> *tiles;
@property (nonatomic, strong) NSMutableArray<YTMUSheetAction *> *actions;
@property (nonatomic, strong) UIView *dimView;
@property (nonatomic, strong) UIView *sheet;
@property (nonatomic) BOOL shown;
@property (nonatomic) BOOL closing;
@end

@implementation YTMUActionSheet

+ (instancetype)sheetWithTitle:(NSString *)title subtitle:(NSString *)subtitle {
    YTMUActionSheet *sheet = [[YTMUActionSheet alloc] initWithNibName:nil bundle:nil];
    sheet.sheetTitle = title;
    sheet.sheetSubtitle = subtitle;
    sheet.tiles = [NSMutableArray array];
    sheet.actions = [NSMutableArray array];
    sheet.modalPresentationStyle = UIModalPresentationOverFullScreen;
    sheet.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    return sheet;
}

- (void)addTile:(YTMUSheetAction *)action {
    if (action)
        [self.tiles addObject:action];
}

- (void)addAction:(YTMUSheetAction *)action {
    if (action)
        [self.actions addObject:action];
}

- (void)presentFrom:(UIViewController *)presenter {
    if (!presenter)
        return;
    // Present from the top-most screen (a sheet may be open already)
    while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed)
        presenter = presenter.presentedViewController;
    [presenter presentViewController:self animated:NO completion:nil];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

#pragma mark Layout

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    self.dimView = [UIView new];
    self.dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    self.dimView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.dimView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)]];
    [self.view addSubview:self.dimView];

    self.sheet = [UIView new];
    self.sheet.backgroundColor = YTMUSheetBackground();
    self.sheet.layer.cornerRadius = 16;
    self.sheet.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    self.sheet.clipsToBounds = YES;
    self.sheet.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.sheet];

    UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(close)];
    swipe.direction = UISwipeGestureRecognizerDirectionDown;
    [self.sheet addGestureRecognizer:swipe];

    // Header: title, subtitle, ✕
    UILabel *title = [UILabel new];
    title.text = self.sheetTitle;
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    title.textColor = [UIColor whiteColor];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *subtitle = [UILabel new];
    subtitle.text = self.sheetSubtitle;
    subtitle.font = [UIFont systemFontOfSize:15];
    subtitle.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeButton setImage:YTMUSheetIcon(@"xmark", 20) forState:UIControlStateNormal];
    closeButton.tintColor = [UIColor whiteColor];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [closeButton addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    UIView *line = [UIView new];
    line.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.15];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    for (UIView *view in @[title, subtitle, closeButton, line])
        [self.sheet addSubview:view];

    // Tiles + rows, scrollable when long
    UIScrollView *scroll = [UIScrollView new];
    scroll.alwaysBounceVertical = NO;
    scroll.showsVerticalScrollIndicator = NO;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sheet addSubview:scroll];

    UIStackView *content = [UIStackView new];
    content.axis = UILayoutConstraintAxisVertical;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];

    if (self.tiles.count) {
        UIStackView *tileRow = [UIStackView new];
        tileRow.axis = UILayoutConstraintAxisHorizontal;
        tileRow.distribution = UIStackViewDistributionFillEqually;
        tileRow.spacing = 12;
        for (NSUInteger i = 0; i < self.tiles.count; i++)
            [tileRow addArrangedSubview:[self tileForAction:self.tiles[i] tag:(NSInteger)i]];
        UIView *tilePadding = [UIView new];
        tileRow.translatesAutoresizingMaskIntoConstraints = NO;
        [tilePadding addSubview:tileRow];
        [NSLayoutConstraint activateConstraints:@[
            [tileRow.topAnchor constraintEqualToAnchor:tilePadding.topAnchor constant:18],
            [tileRow.bottomAnchor constraintEqualToAnchor:tilePadding.bottomAnchor constant:-14],
            [tileRow.leadingAnchor constraintEqualToAnchor:tilePadding.leadingAnchor constant:18],
            [tileRow.trailingAnchor constraintEqualToAnchor:tilePadding.trailingAnchor constant:-18]
        ]];
        [content addArrangedSubview:tilePadding];
    }
    for (NSUInteger i = 0; i < self.actions.count; i++)
        [content addArrangedSubview:[self rowForAction:self.actions[i] tag:(NSInteger)i]];
    UIView *bottomSpace = [UIView new];
    [bottomSpace.heightAnchor constraintEqualToConstant:8].active = YES;
    [content addArrangedSubview:bottomSpace];

    NSLayoutConstraint *fitContent = [scroll.heightAnchor constraintEqualToAnchor:content.heightAnchor];
    fitContent.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [self.dimView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.dimView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.dimView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.dimView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [self.sheet.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.sheet.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [self.sheet.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.sheet.topAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:40],

        [title.topAnchor constraintEqualToAnchor:self.sheet.topAnchor constant:20],
        [title.leadingAnchor constraintEqualToAnchor:self.sheet.leadingAnchor constant:18],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:closeButton.leadingAnchor constant:-8],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [subtitle.trailingAnchor constraintLessThanOrEqualToAnchor:closeButton.leadingAnchor constant:-8],
        [closeButton.trailingAnchor constraintEqualToAnchor:self.sheet.trailingAnchor constant:-12],
        [closeButton.centerYAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
        [closeButton.widthAnchor constraintEqualToConstant:44],
        [closeButton.heightAnchor constraintEqualToConstant:44],
        [line.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:18],
        [line.leadingAnchor constraintEqualToAnchor:self.sheet.leadingAnchor],
        [line.trailingAnchor constraintEqualToAnchor:self.sheet.trailingAnchor],
        [line.heightAnchor constraintEqualToConstant:1],

        [scroll.topAnchor constraintEqualToAnchor:line.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.sheet.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.sheet.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.sheet.safeAreaLayoutGuide.bottomAnchor],
        fitContent,

        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]
    ]];
}

// Big rounded button with the icon, label under it (Play next / Share)
- (UIView *)tileForAction:(YTMUSheetAction *)action tag:(NSInteger)tag {
    UIControl *tile = [UIControl new];
    tile.tag = tag;
    [tile addTarget:self action:@selector(tileTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIView *box = [UIView new];
    box.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    box.layer.cornerRadius = 12;
    box.userInteractionEnabled = NO;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageView *icon = [[UIImageView alloc] initWithImage:YTMUSheetIcon(action.symbol, 21)];
    icon.tintColor = [UIColor whiteColor];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *label = [UILabel new];
    label.text = action.title;
    label.font = [UIFont systemFontOfSize:15];
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.8;
    label.translatesAutoresizingMaskIntoConstraints = NO;

    [tile addSubview:box];
    [box addSubview:icon];
    [tile addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [box.topAnchor constraintEqualToAnchor:tile.topAnchor],
        [box.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor],
        [box.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor],
        [box.heightAnchor constraintEqualToConstant:64],
        [icon.centerXAnchor constraintEqualToAnchor:box.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
        [label.topAnchor constraintEqualToAnchor:box.bottomAnchor constant:10],
        [label.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor],
        [label.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor],
        [label.bottomAnchor constraintEqualToAnchor:tile.bottomAnchor]
    ]];
    return tile;
}

// Icon + text row
- (UIView *)rowForAction:(YTMUSheetAction *)action tag:(NSInteger)tag {
    UIControl *row = [UIControl new];
    row.tag = tag;
    [row addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];
    [row addTarget:self action:@selector(rowHighlight:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [row addTarget:self action:@selector(rowUnhighlight:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];

    UIImageView *icon = [[UIImageView alloc] initWithImage:YTMUSheetIcon(action.symbol, 21)];
    icon.tintColor = [UIColor whiteColor];
    icon.contentMode = UIViewContentModeCenter;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *label = [UILabel new];
    label.text = action.title;
    label.font = [UIFont systemFontOfSize:17];
    label.textColor = [UIColor whiteColor];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:icon];
    [row addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:52],
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:18],
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:30],
        [label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:66],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor constant:-16],
        [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
    ]];
    return row;
}

- (void)rowHighlight:(UIControl *)row {
    row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
}

- (void)rowUnhighlight:(UIControl *)row {
    row.backgroundColor = [UIColor clearColor];
}

#pragma mark Show / hide

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.shown)
        return;
    [self.view layoutIfNeeded];
    self.dimView.alpha = 0;
    self.sheet.transform = CGAffineTransformMakeTranslation(0, self.sheet.bounds.size.height + 40);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.shown)
        return;
    self.shown = YES;
    [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.95 initialSpringVelocity:0.3 options:0 animations:^{
        self.dimView.alpha = 1;
        self.sheet.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)closeThen:(void (^)(void))then {
    if (self.closing)
        return;
    self.closing = YES;
    [UIView animateWithDuration:0.2 animations:^{
        self.dimView.alpha = 0;
        self.sheet.transform = CGAffineTransformMakeTranslation(0, self.sheet.bounds.size.height + 40);
    } completion:^(BOOL finished) {
        [self dismissViewControllerAnimated:NO completion:^{
            if (then)
                then();
        }];
    }];
}

- (void)close {
    [self closeThen:nil];
}

- (void)tileTapped:(UIControl *)tile {
    YTMUSheetAction *action = self.tiles[(NSUInteger)tile.tag];
    [self closeThen:action.handler];
}

- (void)rowTapped:(UIControl *)row {
    YTMUSheetAction *action = self.actions[(NSUInteger)row.tag];
    [self closeThen:action.handler];
}

@end

void YTMUShowInfoBox(UIViewController *presenter, NSString *text) {
    UIView *host = presenter.view.window ?: presenter.view;
    if (!host)
        return;
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;

    UIView *box = [UIView new];
    box.backgroundColor = YTMUSheetBackground();
    box.layer.cornerRadius = 10;
    if (YTMUIsOLED()) {
        box.layer.borderWidth = 1;
        box.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
    }
    [box addSubview:label];

    CGFloat maxWidth = MIN(host.bounds.size.width - 80, 300);
    CGSize textSize = [label sizeThatFits:CGSizeMake(maxWidth - 40, CGFLOAT_MAX)];
    box.frame = CGRectMake(0, 0, textSize.width + 48, textSize.height + 36);
    label.frame = CGRectInset(box.bounds, 24, 18);
    box.center = CGPointMake(CGRectGetMidX(host.bounds), CGRectGetMidY(host.bounds));
    box.alpha = 0;
    [host addSubview:box];
    [UIView animateWithDuration:0.18 animations:^{
        box.alpha = 1;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.3 delay:1.4 options:0 animations:^{
            box.alpha = 0;
        } completion:^(BOOL done) {
            [box removeFromSuperview];
        }];
    }];
}
