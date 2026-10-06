#import "TTXRootListController.h"
#import <notify.h>

#define kTTXSuite         CFSTR("com.tiktokx")
#define kTTXPrefsChanged  "com.tiktokx/prefsChanged"
#define kTTXLanguage      @"language"

#ifndef TTX_VERSION
#define TTX_VERSION "?"
#endif

// Bit trong state cua notification (TikTok bi sandbox nen khong doc duoc plist,
// nhung doc duoc state nay). bit10 = da ghi (doi khi them cong tac), bit1 = nhac nen, bit2 = tu cuon,
// bit3 = doi nut tua thanh bai truoc / bai sau, bit4 = an giao dien phu tren video,
// bit5 = phong to vua phai video doc tren man hinh xe.
#define kTTXStateValid       (1ULL << 10)
#define kTTXStateBackground  (1ULL << 1)
#define kTTXStateAutoNext    (1ULL << 2)
#define kTTXStateRemoteScroll (1ULL << 3)
#define kTTXStateClearDisplay (1ULL << 4)
#define kTTXStateCarZoom     (1ULL << 5)

static id TTXPrefValue(CFStringRef key) {
	CFPropertyListRef value = CFPreferencesCopyAppValue(key, kTTXSuite);
	return value ? (__bridge_transfer id)value : nil;
}

// "Clear Display" mac dinh tat, cac cong tac khac mac dinh bat
static BOOL TTXDefaultFor(NSString *key) {
	return ![key isEqualToString:@"clearDisplay"];
}

static BOOL TTXPrefBool(CFStringRef key) {
	id obj = TTXPrefValue(key);
	return [obj respondsToSelector:@selector(boolValue)] ? [obj boolValue] : TTXDefaultFor((__bridge NSString *)key);
}

// Ghi gia tri hien tai vao state roi bao cho TikTok doc lai
static void TTXPublishPrefs(void) {
	CFPreferencesAppSynchronize(kTTXSuite);
	uint64_t state = kTTXStateValid;
	if (TTXPrefBool(CFSTR("backgroundAudio"))) state |= kTTXStateBackground;
	if (TTXPrefBool(CFSTR("autoNext"))) state |= kTTXStateAutoNext;
	if (TTXPrefBool(CFSTR("remoteScroll"))) state |= kTTXStateRemoteScroll;
	if (TTXPrefBool(CFSTR("clearDisplay"))) state |= kTTXStateClearDisplay;
	if (TTXPrefBool(CFSTR("carZoom"))) state |= kTTXStateCarZoom;

	int token;
	if (notify_register_check(kTTXPrefsChanged, &token) == NOTIFY_STATUS_OK) {
		notify_set_state(token, state);
		notify_cancel(token);
	}
	notify_post(kTTXPrefsChanged);
}

// Ban truoc 1.0.31 luu cai dat o com.anlai.tiktokx: chep sang ten moi neu chua co
static void TTXMigrateOldPrefs(void) {
	CFStringRef oldSuite = CFSTR("com.anlai.tiktokx");
	for (NSString *key in @[@"backgroundAudio", @"autoNext", @"remoteScroll", @"clearDisplay", @"carZoom", kTTXLanguage]) {
		if (TTXPrefValue((__bridge CFStringRef)key)) continue;
		CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, oldSuite);
		if (!value) continue;
		CFPreferencesSetAppValue((__bridge CFStringRef)key, value, kTTXSuite);
		CFRelease(value);
	}
	CFPreferencesAppSynchronize(kTTXSuite);
}

// Ngon ngu da chon; chua chon thi mac dinh tieng Anh
static NSString *TTXLanguage(void) {
	NSString *lang = TTXPrefValue((__bridge CFStringRef)kTTXLanguage);
	return [lang isKindOfClass:[NSString class]] ? lang : @"en";
}

static NSString *TTXText(NSString *key) {
	static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *strings;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		strings = @{
			@"en": @{
				@"backgroundAudio": @"Background Play",
				@"backgroundAudio.info": @"Keep audio playing when you leave TikTok or lock the screen.",
				@"autoNext": @"Auto Scroll",
				@"autoNext.info": @"Move to the next video when the current one finishes.",
				@"remoteScroll": @"Skip → Next/Previous",
				@"remoteScroll.info": @"Replace the ±15s buttons on the lock screen and Control Center with previous/next to scroll the feed.",
				@"clearDisplay": @"Clear Display",
				@"clearDisplay.info": @"Hide the buttons, caption, search bar and other overlays on top of videos. Tap the video to show them for 3 seconds.",
				@"carZoom": @"Car Screen Zoom",
				@"carZoom.info": @"On a car display (CarBridge), zoom portrait videos in a little so they fill more of the wide screen. Off: show the whole video.",
				@"language": @"Language",
				@"section.playback": @"Playback",
				@"section.display": @"Controls & Display",
				@"tagline": @"Background play, auto scroll and lock screen controls for TikTok",
				@"about": @"Version %@ · MIT License\n© 2026 AnLai",
			},
			@"vi": @{
				@"backgroundAudio": @"Phát nền",
				@"backgroundAudio.info": @"Tiếp tục phát âm thanh khi rời TikTok hoặc khóa màn hình.",
				@"autoNext": @"Tự cuộn",
				@"autoNext.info": @"Tự chuyển sang video tiếp theo khi video hiện tại phát xong.",
				@"remoteScroll": @"Nút tua → Bài trước/sau",
				@"remoteScroll.info": @"Thay nút tua ±15s trên màn hình khóa và Control Center bằng nút bài trước/bài sau để cuộn feed.",
				@"clearDisplay": @"Loại bỏ yếu tố trên màn hình",
				@"clearDisplay.info": @"Ẩn các nút, chú thích, thanh tìm kiếm và lớp giao diện khác phủ trên video. Chạm vào video để hiện lại trong 3 giây.",
				@"carZoom": @"Phóng to trên màn hình xe",
				@"carZoom.info": @"Trên màn hình xe (CarBridge), phóng to vừa phải video dọc để phủ nhiều hơn màn hình rộng. Tắt: hiện trọn video.",
				@"language": @"Ngôn ngữ",
				@"section.playback": @"Phát lại",
				@"section.display": @"Điều khiển & hiển thị",
				@"tagline": @"Phát nền, tự cuộn và điều khiển màn hình khóa cho TikTok",
				@"about": @"Phiên bản %@ · Giấy phép MIT\n© 2026 AnLai",
			},
		};
	});
	return strings[TTXLanguage()][key] ?: strings[@"en"][key] ?: key;
}

#pragma mark - Mau va icon kieu HarmonyOS

static UIColor *TTXDynamic(uint32_t light, uint32_t dark) {
	UIColor *(^rgb)(uint32_t) = ^(uint32_t hex) {
		return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0 green:((hex >> 8) & 0xFF) / 255.0 blue:(hex & 0xFF) / 255.0 alpha:1];
	};
	UIColor *l = rgb(light), *d = rgb(dark);
	return [UIColor colorWithDynamicProvider:^(UITraitCollection *t) {
		return t.userInterfaceStyle == UIUserInterfaceStyleDark ? d : l;
	}];
}

// Nen xam nhat, the trang, chu va mau nhan (xanh HarmonyOS) giong app Cai dat cua HarmonyOS
#define kTTXBackground TTXDynamic(0xF1F3F5, 0x000000)
#define kTTXCard       TTXDynamic(0xFFFFFF, 0x202224)
#define kTTXPrimary    TTXDynamic(0x182431, 0xE5E5E5)
#define kTTXSecondary  TTXDynamic(0x7A8086, 0x8C9196)
#define kTTXDivider    TTXDynamic(0xE3E5E8, 0x323436)
#define kTTXAccent     TTXDynamic(0x0A59F7, 0x317AF7)

// O vuong bo goc mau, SF Symbol trang o giua
static UIImage *TTXIcon(NSString *symbol, UIColor *color) {
	CGRect rect = CGRectMake(0, 0, 32, 32);
	UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:rect.size];
	return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
		[color setFill];
		[[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:9] fill];
		UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightMedium];
		UIImage *glyph = [[UIImage systemImageNamed:symbol withConfiguration:config] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
		CGSize size = glyph.size;
		[glyph drawInRect:CGRectMake((rect.size.width - size.width) / 2, (rect.size.height - size.height) / 2, size.width, size.height)];
	}];
}

static UIImage *TTXIconForKey(NSString *key) {
	NSDictionary<NSString *, NSArray *> *icons = @{
		@"backgroundAudio": @[@"headphones", TTXDynamic(0xF7365D, 0xF7365D)],
		@"autoNext": @[@"arrow.down", TTXDynamic(0x0A59F7, 0x317AF7)],
		@"remoteScroll": @[@"forward.end.fill", TTXDynamic(0x7B4FF5, 0x8A63F7)],
		@"clearDisplay": @[@"eye.slash.fill", TTXDynamic(0xFF7500, 0xFF8A26)],
		@"carZoom": @[@"car.fill", TTXDynamic(0x00A86B, 0x1FBF84)],
	};
	return TTXIcon(icons[key][0], icons[key][1]);
}

#pragma mark - Dong cong tac

// Mot dong trong the: icon, ten, mo ta va cong tac; cham ca dong cung bat/tat
@interface TTXSwitchRow : UIControl
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) UISwitch *toggle;
@end

@implementation TTXSwitchRow

- (instancetype)initWithKey:(NSString *)key {
	if ((self = [super initWithFrame:CGRectZero])) {
		_key = key;

		UIImageView *icon = [[UIImageView alloc] initWithImage:TTXIconForKey(key)];
		[icon setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

		UILabel *title = [UILabel new];
		title.text = TTXText(key);
		title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
		title.textColor = kTTXPrimary;
		title.numberOfLines = 0;

		UILabel *info = [UILabel new];
		info.text = TTXText([key stringByAppendingString:@".info"]);
		info.font = [UIFont systemFontOfSize:13];
		info.textColor = kTTXSecondary;
		info.numberOfLines = 0;

		UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[title, info]];
		texts.axis = UILayoutConstraintAxisVertical;
		texts.spacing = 2;

		_toggle = [UISwitch new];
		_toggle.onTintColor = kTTXAccent;
		_toggle.on = TTXPrefBool((__bridge CFStringRef)key);
		[_toggle setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
		[_toggle setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
		[_toggle addTarget:self action:@selector(toggleChanged) forControlEvents:UIControlEventValueChanged];

		UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[icon, texts, _toggle]];
		row.alignment = UIStackViewAlignmentCenter;
		row.spacing = 12;
		row.translatesAutoresizingMaskIntoConstraints = NO;
		[self addSubview:row];
		[NSLayoutConstraint activateConstraints:@[
			[row.topAnchor constraintEqualToAnchor:self.topAnchor constant:14],
			[row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-14],
			[row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
			[row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
		]];

		[self addTarget:self action:@selector(rowTapped) forControlEvents:UIControlEventTouchUpInside];
		self.accessibilityLabel = title.text;
		self.accessibilityHint = info.text;
	}
	return self;
}

// Cham vao cong tac thi de cong tac xu ly, cham cho khac trong dong thi dong nhan
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
	if (![self pointInside:point withEvent:event]) return nil;
	CGPoint inToggle = [self convertPoint:point toView:self.toggle];
	if ([self.toggle pointInside:inToggle withEvent:event]) return self.toggle;
	return self;
}

- (void)setHighlighted:(BOOL)highlighted {
	[super setHighlighted:highlighted];
	[UIView animateWithDuration:0.15 animations:^{
		self.backgroundColor = highlighted ? [kTTXPrimary colorWithAlphaComponent:0.05] : UIColor.clearColor;
	}];
}

- (void)rowTapped {
	[self.toggle setOn:!self.toggle.on animated:YES];
	[self toggleChanged];
}

- (void)toggleChanged {
	CFPreferencesSetAppValue((__bridge CFStringRef)self.key, (__bridge CFPropertyListRef)@(self.toggle.on), kTTXSuite);
	TTXPublishPrefs();
	[[UISelectionFeedbackGenerator new] selectionChanged];
}

@end

#pragma mark - Man hinh chinh

@implementation TTXRootListController {
	UIScrollView *_scroll;
	UIStackView *_content;
	UILabel *_largeTitle;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	TTXMigrateOldPrefs();
	// State mat sau khi reboot: mo Settings la ghi lai
	TTXPublishPrefs();

	self.view.backgroundColor = kTTXBackground;
	_scroll = [UIScrollView new];
	_scroll.alwaysBounceVertical = YES;
	_scroll.delegate = self;
	_scroll.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:_scroll];

	_content = [UIStackView new];
	_content.axis = UILayoutConstraintAxisVertical;
	_content.translatesAutoresizingMaskIntoConstraints = NO;
	[_scroll addSubview:_content];

	[NSLayoutConstraint activateConstraints:@[
		[_scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
		[_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[_content.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:4],
		[_content.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-24],
		[_content.leadingAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.leadingAnchor constant:16],
		[_content.trailingAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.trailingAnchor constant:-16],
	]];

	[self rebuild];
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
	[self updateNavigationTitle];
}

// Dung lai toan bo noi dung theo ngon ngu hien tai
- (void)rebuild {
	for (UIView *view in _content.arrangedSubviews) [view removeFromSuperview];

	[_content addArrangedSubview:[self makeHeader]];
	[_content setCustomSpacing:28 afterView:_content.arrangedSubviews.lastObject];

	[self addSection:@"section.playback" keys:@[@"backgroundAudio", @"autoNext"]];
	[self addSection:@"section.display" keys:@[@"remoteScroll", @"clearDisplay", @"carZoom"]];

	UILabel *about = [UILabel new];
	about.text = [NSString stringWithFormat:TTXText(@"about"), @TTX_VERSION];
	about.font = [UIFont systemFontOfSize:12];
	about.textColor = kTTXSecondary;
	about.textAlignment = NSTextAlignmentCenter;
	about.numberOfLines = 0;
	[_content addArrangedSubview:about];

	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:[self languageButton]];
}

// Tieu de lon can trai kem dong gioi thieu, icon tweak ben phai
- (UIView *)makeHeader {
	_largeTitle = [UILabel new];
	_largeTitle.text = @"TikTokX";
	_largeTitle.font = [UIFont systemFontOfSize:30 weight:UIFontWeightBold];
	_largeTitle.textColor = kTTXPrimary;

	UILabel *tagline = [UILabel new];
	tagline.text = TTXText(@"tagline");
	tagline.font = [UIFont systemFontOfSize:14];
	tagline.textColor = kTTXSecondary;
	tagline.numberOfLines = 0;

	UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[_largeTitle, tagline]];
	texts.axis = UILayoutConstraintAxisVertical;
	texts.spacing = 4;

	UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"icon" inBundle:[NSBundle bundleForClass:self.class] compatibleWithTraitCollection:nil]];
	icon.contentMode = UIViewContentModeScaleAspectFill;
	icon.layer.cornerRadius = 14;
	icon.layer.cornerCurve = kCACornerCurveContinuous;
	icon.clipsToBounds = YES;
	[icon.widthAnchor constraintEqualToConstant:56].active = YES;
	[icon.heightAnchor constraintEqualToConstant:56].active = YES;

	UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[texts, icon]];
	header.alignment = UIStackViewAlignmentCenter;
	header.spacing = 16;
	header.layoutMarginsRelativeArrangement = YES;
	header.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(0, 8, 0, 4);
	return header;
}

// Tieu de nho mau xam phia tren, cac dong nam chung mot the bo goc lon, ngan cach bang duong manh
- (void)addSection:(NSString *)titleKey keys:(NSArray<NSString *> *)keys {
	UILabel *title = [UILabel new];
	title.text = TTXText(titleKey);
	title.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
	title.textColor = kTTXSecondary;
	UIStackView *titleWrap = [[UIStackView alloc] initWithArrangedSubviews:@[title]];
	titleWrap.layoutMarginsRelativeArrangement = YES;
	titleWrap.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(0, 12, 0, 12);
	[_content addArrangedSubview:titleWrap];
	[_content setCustomSpacing:8 afterView:titleWrap];

	UIStackView *rows = [UIStackView new];
	rows.axis = UILayoutConstraintAxisVertical;
	for (NSString *key in keys) {
		if (rows.arrangedSubviews.count) {
			// Duong ngan cach bat dau tu cot chu, khong cham icon
			UIView *line = [UIView new];
			line.backgroundColor = kTTXDivider;
			line.translatesAutoresizingMaskIntoConstraints = NO;
			UIView *divider = [UIView new];
			[divider addSubview:line];
			[NSLayoutConstraint activateConstraints:@[
				[divider.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale],
				[line.topAnchor constraintEqualToAnchor:divider.topAnchor],
				[line.bottomAnchor constraintEqualToAnchor:divider.bottomAnchor],
				[line.leadingAnchor constraintEqualToAnchor:divider.leadingAnchor constant:56],
				[line.trailingAnchor constraintEqualToAnchor:divider.trailingAnchor constant:-12],
			]];
			[rows addArrangedSubview:divider];
		}
		[rows addArrangedSubview:[[TTXSwitchRow alloc] initWithKey:key]];
	}

	UIView *card = [UIView new];
	card.backgroundColor = kTTXCard;
	card.layer.cornerRadius = 20;
	card.layer.cornerCurve = kCACornerCurveContinuous;
	card.clipsToBounds = YES;
	rows.translatesAutoresizingMaskIntoConstraints = NO;
	[card addSubview:rows];
	[NSLayoutConstraint activateConstraints:@[
		[rows.topAnchor constraintEqualToAnchor:card.topAnchor constant:4],
		[rows.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-4],
		[rows.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
		[rows.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
	]];
	[_content addArrangedSubview:card];
	[_content setCustomSpacing:24 afterView:card];
}

// Nut vien thuoc o goc phai: icon qua dia cau + ma ngon ngu, cham de hien menu chon
- (UIButton *)languageButton {
	NSString *current = TTXLanguage();
	NSArray *codes = @[@"en", @"vi"];
	NSArray *names = @[@"English", @"Tiếng Việt"];
	NSMutableArray *actions = [NSMutableArray array];
	__weak typeof(self) weakSelf = self;
	for (NSUInteger i = 0; i < codes.count; i++) {
		NSString *code = codes[i];
		UIAction *action = [UIAction actionWithTitle:names[i] image:nil identifier:nil handler:^(UIAction *a) {
			[weakSelf setLanguage:code];
		}];
		action.state = [code isEqualToString:current] ? UIMenuElementStateOn : UIMenuElementStateOff;
		[actions addObject:action];
	}

	UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
	config.baseBackgroundColor = [kTTXPrimary colorWithAlphaComponent:0.06];
	config.baseForegroundColor = kTTXPrimary;
	config.image = [UIImage systemImageNamed:@"globe" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightMedium]];
	config.imagePadding = 5;
	config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
	config.contentInsets = NSDirectionalEdgeInsetsMake(6, 11, 6, 12);
	config.attributedTitle = [[NSAttributedString alloc] initWithString:current.uppercaseString
		attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]}];

	UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
	button.menu = [UIMenu menuWithTitle:TTXText(@"language") children:actions];
	button.showsMenuAsPrimaryAction = YES;
	button.accessibilityLabel = TTXText(@"language");
	return button;
}

- (void)setLanguage:(NSString *)code {
	if ([code isEqualToString:TTXLanguage()]) return;
	CFPreferencesSetAppValue((__bridge CFStringRef)kTTXLanguage, (__bridge CFStringRef)code, kTTXSuite);
	CFPreferencesAppSynchronize(kTTXSuite);
	[UIView transitionWithView:_content duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
		[self rebuild];
	} completion:nil];
}

// Nhu HarmonyOS: tieu de chi hien tren thanh dieu huong khi tieu de lon da cuon khuat
- (void)updateNavigationTitle {
	if (!_largeTitle) return;
	CGRect frame = [_largeTitle convertRect:_largeTitle.bounds toView:_scroll];
	BOOL largeVisible = CGRectIsEmpty(frame) || _scroll.contentOffset.y + _scroll.adjustedContentInset.top < CGRectGetMaxY(frame);
	NSString *title = largeVisible ? @"" : @"TikTokX";
	if (![self.navigationItem.title isEqualToString:title]) self.navigationItem.title = title;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
	[self updateNavigationTitle];
}

@end

