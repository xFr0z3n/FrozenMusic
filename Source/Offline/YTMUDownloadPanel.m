#import "YTMUDownloadPanel.h"
#import "YTMUOfflineUI.h"

@implementation YTMUPanelButton

+ (instancetype)buttonWithTitle:(NSString *)title style:(YTMUPanelButtonStyle)style handler:(void (^)(void))handler {
    YTMUPanelButton *button = [YTMUPanelButton new];
    button.title = title;
    button.style = style;
    button.handler = handler;
    return button;
}

@end

// Thin progress line (white on a faint track)
@interface YTMUPanelBar : UIView
@property (nonatomic) float progress;
@property (nonatomic, strong) UIView *fill;
@end

@implementation YTMUPanelBar

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.15];
        self.layer.cornerRadius = 2;
        self.clipsToBounds = YES;
        self.fill = [UIView new];
        self.fill.backgroundColor = [UIColor whiteColor];
        self.fill.layer.cornerRadius = 2;
        [self addSubview:self.fill];
    }
    return self;
}

- (void)setProgress:(float)progress {
    _progress = MAX(0.f, MIN(1.f, progress));
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.fill.frame = CGRectMake(0, 0, self.bounds.size.width * self.progress, self.bounds.size.height);
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, 4);
}

@end

static __weak YTMUDownloadPanel *YTMUCurrentPanel = nil;

@interface YTMUDownloadPanel ()
@property (nonatomic, readwrite) BOOL atTop;
@property (nonatomic) BOOL passThrough;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *stepLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *detailsLabel;
@property (nonatomic, strong) YTMUPanelBar *bar;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIStackView *buttonStack;
@property (nonatomic) BOOL dismissed;
@end

@implementation YTMUDownloadPanel

+ (YTMUDownloadPanel *)current {
    return YTMUCurrentPanel;
}

+ (void)dismissCurrent {
    [YTMUCurrentPanel dismiss];
}

+ (YTMUDownloadPanel *)showCentered {
    return [self showAtTop:NO dimmed:YES];
}

+ (YTMUDownloadPanel *)showAtTop {
    return [self showAtTop:YES dimmed:NO];
}

+ (void)showMessage:(NSString *)title details:(NSString *)details symbol:(NSString *)symbol {
    YTMUDownloadPanel *panel = [self showAtTop:NO dimmed:NO];
    if (!panel)
        return;
    panel.passThrough = YES;
    if (symbol) {
        panel.iconView.image = [[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightMedium]] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        panel.iconView.hidden = panel.iconView.image == nil;
    }
    panel.title = title;
    panel.details = details;
    panel.progress = NAN;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:panel action:@selector(dismiss)];
    [panel.card addGestureRecognizer:tap];
    __weak YTMUDownloadPanel *weakPanel = panel;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakPanel dismiss];
    });
}

+ (YTMUDownloadPanel *)showAtTop:(BOOL)top dimmed:(BOOL)dimmed {
    [YTMUCurrentPanel removeFromSuperview];
    YTMUCurrentPanel = nil;
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window)
        return nil;
    YTMUDownloadPanel *panel = [[YTMUDownloadPanel alloc] initWithFrame:window.bounds top:top dimmed:dimmed];
    [window addSubview:panel];
    YTMUCurrentPanel = panel;

    panel.alpha = 0;
    panel.card.transform = top ? CGAffineTransformMakeTranslation(0, -12) : CGAffineTransformMakeScale(0.96, 0.96);
    [UIView animateWithDuration:YTMUDuration(0.2) delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        panel.alpha = 1;
        panel.card.transform = CGAffineTransformIdentity;
    } completion:nil];
    return panel;
}

- (instancetype)initWithFrame:(CGRect)frame top:(BOOL)top dimmed:(BOOL)dimmed {
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    self.atTop = top;
    self.passThrough = !dimmed;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundColor = dimmed ? [UIColor colorWithWhite:0 alpha:0.55] : [UIColor clearColor];
    BOOL oled = YTMUIsOLED();

    self.card = [UIView new];
    self.card.translatesAutoresizingMaskIntoConstraints = NO;
    self.card.backgroundColor = oled ? [UIColor blackColor] : [UIColor colorWithRed:0.13 green:0.13 blue:0.13 alpha:1.0];
    self.card.layer.cornerRadius = 14;
    if (oled) {
        self.card.layer.borderWidth = 1;
        self.card.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
    }
    self.card.layer.shadowColor = [UIColor blackColor].CGColor;
    self.card.layer.shadowOpacity = 0.35;
    self.card.layer.shadowRadius = 16;
    self.card.layer.shadowOffset = CGSizeMake(0, 6);
    [self addSubview:self.card];

    NSTextAlignment alignment = top ? NSTextAlignmentNatural : NSTextAlignmentCenter;

    self.iconView = [UIImageView new];
    self.iconView.tintColor = [UIColor whiteColor];
    self.iconView.contentMode = UIViewContentModeCenter;
    self.iconView.hidden = YES;
    [self.iconView.heightAnchor constraintEqualToConstant:40].active = YES;

    self.stepLabel = [UILabel new];
    self.stepLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    self.stepLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    self.stepLabel.textAlignment = alignment;
    self.stepLabel.hidden = YES;

    self.titleLabel = [UILabel new];
    self.titleLabel.font = [UIFont systemFontOfSize:top ? 15 : 17 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.textAlignment = alignment;
    self.titleLabel.numberOfLines = top ? 1 : 2;

    self.detailsLabel = [UILabel new];
    self.detailsLabel.font = [UIFont systemFontOfSize:13];
    self.detailsLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
    self.detailsLabel.textAlignment = alignment;
    self.detailsLabel.numberOfLines = 0;
    self.detailsLabel.hidden = YES;

    self.bar = [YTMUPanelBar new];
    self.bar.hidden = YES;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.color = [UIColor whiteColor];
    self.spinner.hidesWhenStopped = NO;
    self.spinner.hidden = YES;

    self.buttonStack = [UIStackView new];
    self.buttonStack.axis = top ? UILayoutConstraintAxisHorizontal : UILayoutConstraintAxisVertical;
    self.buttonStack.spacing = 8;
    self.buttonStack.distribution = UIStackViewDistributionFillEqually;
    self.buttonStack.hidden = YES;

    self.stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.iconView, self.stepLabel, self.titleLabel, self.detailsLabel, self.spinner, self.bar, self.buttonStack]];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 6;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack setCustomSpacing:2 afterView:self.stepLabel];
    [self.stack setCustomSpacing:12 afterView:self.detailsLabel];
    [self.stack setCustomSpacing:14 afterView:self.bar];
    [self.stack setCustomSpacing:14 afterView:self.spinner];
    [self.card addSubview:self.stack];

    CGFloat inset = top ? 14 : 20;
    NSLayoutConstraint *width = [self.card.widthAnchor constraintEqualToConstant:top ? 420 : 340];
    width.priority = UILayoutPriorityDefaultHigh;
    NSMutableArray *constraints = [@[
        width,
        [self.card.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [self.card.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.safeAreaLayoutGuide.leadingAnchor constant:top ? 12 : 28],
        [self.stack.topAnchor constraintEqualToAnchor:self.card.topAnchor constant:inset],
        [self.stack.bottomAnchor constraintEqualToAnchor:self.card.bottomAnchor constant:-inset],
        [self.stack.leadingAnchor constraintEqualToAnchor:self.card.leadingAnchor constant:inset + 2],
        [self.stack.trailingAnchor constraintEqualToAnchor:self.card.trailingAnchor constant:-inset - 2],
    ] mutableCopy];
    if (top) {
        [constraints addObject:[self.card.topAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.topAnchor constant:6]];
    } else {
        [constraints addObject:[self.card.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]];
        [constraints addObject:[self.card.topAnchor constraintGreaterThanOrEqualToAnchor:self.safeAreaLayoutGuide.topAnchor constant:20]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
    _progress = NAN;
    return self;
}

// Only the box takes taps when the page below should stay usable
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (self.passThrough && hit == self)
        return nil;
    return hit;
}

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    self.titleLabel.text = title;
    self.titleLabel.hidden = title.length == 0;
}

- (void)setStep:(NSString *)step {
    _step = [step copy];
    self.stepLabel.text = step.uppercaseString;
    self.stepLabel.hidden = step.length == 0;
}

- (void)setDetails:(NSString *)details {
    _details = [details copy];
    self.detailsLabel.text = details;
    self.detailsLabel.hidden = details.length == 0;
}

- (void)setProgress:(float)progress {
    _progress = progress;
    if (isnan(progress)) {
        self.bar.hidden = YES;
        self.spinner.hidden = YES;
        [self.spinner stopAnimating];
    } else if (progress < 0) {
        self.bar.hidden = YES;
        self.spinner.hidden = NO;
        [self.spinner startAnimating];
    } else {
        self.spinner.hidden = YES;
        [self.spinner stopAnimating];
        self.bar.hidden = NO;
        self.bar.progress = progress;
    }
}

- (void)setButtons:(NSArray<YTMUPanelButton *> *)buttons {
    _buttons = [buttons copy];
    for (UIView *view in self.buttonStack.arrangedSubviews) {
        [self.buttonStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    BOOL oled = YTMUIsOLED();
    CGFloat height = self.atTop ? 32 : 42;
    [buttons enumerateObjectsUsingBlock:^(YTMUPanelButton *item, NSUInteger i, BOOL *stop) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = (NSInteger)i;
        [button setTitle:item.title forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:self.atTop ? 13 : 15 weight:UIFontWeightSemibold];
        button.titleLabel.adjustsFontSizeToFitWidth = YES;
        button.titleLabel.minimumScaleFactor = 0.8;
        button.layer.cornerRadius = height / 2;
        UIColor *grey = [UIColor colorWithWhite:1.0 alpha:oled ? 0.14 : 0.1];
        switch (item.style) {
            case YTMUPanelButtonPrimary:
                button.backgroundColor = [UIColor whiteColor];
                [button setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
                break;
            case YTMUPanelButtonSecondary:
                button.backgroundColor = grey;
                [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                break;
            case YTMUPanelButtonDestructive:
                button.backgroundColor = grey;
                [button setTitleColor:[UIColor colorWithRed:1.0 green:0.31 blue:0.27 alpha:1.0] forState:UIControlStateNormal];
                break;
            case YTMUPanelButtonPlain:
                button.backgroundColor = [UIColor clearColor];
                [button setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.7] forState:UIControlStateNormal];
                break;
        }
        [button.heightAnchor constraintEqualToConstant:height].active = YES;
        [button addTarget:self action:@selector(buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.buttonStack addArrangedSubview:button];
    }];
    self.buttonStack.hidden = buttons.count == 0;
    self.buttonStack.userInteractionEnabled = YES;
}

- (void)buttonTapped:(UIButton *)sender {
    if (sender.tag < 0 || (NSUInteger)sender.tag >= self.buttons.count)
        return;
    // One tap per box: the handler changes or replaces it
    self.buttonStack.userInteractionEnabled = NO;
    void (^handler)(void) = self.buttons[(NSUInteger)sender.tag].handler;
    if (handler)
        handler();
}

- (void)dismiss {
    if (self.dismissed)
        return;
    self.dismissed = YES;
    if (YTMUCurrentPanel == self)
        YTMUCurrentPanel = nil;
    self.userInteractionEnabled = NO;
    [UIView animateWithDuration:YTMUDuration(0.2) animations:^{
        self.alpha = 0;
    } completion:^(BOOL finished) {
        [self removeFromSuperview];
    }];
}

@end
