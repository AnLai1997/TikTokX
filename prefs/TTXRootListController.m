#import "TTXRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UIKit/UIKit.h>
#import <notify.h>

#define kPrefsDomain CFSTR("com.tiktokx")
// Key the language choice is stored under ("vi"/"en", same as before the redesign).
#define kLanguageKey CFSTR("language")
#define kTTXPrefsChanged "com.tiktokx/prefsChanged"

#pragma mark - Talking to TikTok

// TikTok is sandboxed and can't read the plist Settings writes, but it can read the state of a
// notification. Keep these bits in sync with Headers.h.
#define kTTXStateValid        (1ULL << 11)
#define kTTXStateBackground   (1ULL << 1)
#define kTTXStateAutoNext     (1ULL << 2)
#define kTTXStateRemoteScroll (1ULL << 3)
#define kTTXStateClearDisplay (1ULL << 4)
#define kTTXStateEnabled      (1ULL << 6)

static NSArray<NSString *> *TTXSwitchKeys(void) {
	return @[@"enabled", @"backgroundAudio", @"autoNext", @"remoteScroll", @"clearDisplay"];
}

static id TTXPrefValue(CFStringRef key) {
	return (__bridge_transfer id)CFPreferencesCopyAppValue(key, kPrefsDomain);
}

// "Clear Display" is off by default, every other switch is on.
static BOOL TTXPrefBool(NSString *key) {
	id obj = TTXPrefValue((__bridge CFStringRef)key);
	return [obj respondsToSelector:@selector(boolValue)] ? [obj boolValue] : ![key isEqualToString:@"clearDisplay"];
}

// Write the current values into the notification state, then tell TikTok to re-read it.
static void TTXPublishPrefs(void) {
	CFPreferencesAppSynchronize(kPrefsDomain);
	uint64_t state = kTTXStateValid;
	if (TTXPrefBool(@"enabled")) state |= kTTXStateEnabled;
	if (TTXPrefBool(@"backgroundAudio")) state |= kTTXStateBackground;
	if (TTXPrefBool(@"autoNext")) state |= kTTXStateAutoNext;
	if (TTXPrefBool(@"remoteScroll")) state |= kTTXStateRemoteScroll;
	if (TTXPrefBool(@"clearDisplay")) state |= kTTXStateClearDisplay;

	int token;
	if (notify_register_check(kTTXPrefsChanged, &token) == NOTIFY_STATUS_OK) {
		notify_set_state(token, state);
		notify_cancel(token);
	}
	notify_post(kTTXPrefsChanged);
}

// Before 1.0.31 settings lived in com.anlai.tiktokx: copy them over if the new domain lacks them.
static void TTXMigrateOldPrefs(void) {
	CFStringRef oldDomain = CFSTR("com.anlai.tiktokx");
	for (NSString *key in [TTXSwitchKeys() arrayByAddingObject:(__bridge NSString *)kLanguageKey]) {
		if (TTXPrefValue((__bridge CFStringRef)key)) continue;
		CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, oldDomain);
		if (!value) continue;
		CFPreferencesSetAppValue((__bridge CFStringRef)key, value, kPrefsDomain);
		CFRelease(value);
	}
	CFPreferencesAppSynchronize(kPrefsDomain);
}

#pragma mark - Localization

// The app language is picked in the nav bar, so strings come from <lang>.lproj by hand
// instead of following the system language.
static NSDictionary<NSString *, NSString *> *sStrings;

static NSArray<NSString *> *TTXLanguages(void) {
	return @[@"vi", @"en"];
}

static NSString *TTXLanguageName(NSString *lang) {
	return [lang isEqualToString:@"vi"] ? @"Tiếng Việt" : @"English";
}

// No choice yet: English, as before the redesign.
static NSString *TTXLanguage(void) {
	NSString *lang = TTXPrefValue(kLanguageKey);
	return [lang isKindOfClass:[NSString class]] && [TTXLanguages() containsObject:lang] ? lang : @"en";
}

static void TTXLoadStrings(void) {
	NSString *bundlePath = [NSBundle bundleForClass:NSClassFromString(@"TTXRootListController")].bundlePath;
	NSString *path = [bundlePath stringByAppendingFormat:@"/%@.lproj/Localizable.strings", TTXLanguage()];
	sStrings = [NSDictionary dictionaryWithContentsOfFile:path] ?: @{};
}

static NSString *L(NSString *key) {
	return sStrings[key] ?: key;
}

#pragma mark - HarmonyOS theme

static UIColor *TTXDynamicColor(UInt32 light, UInt32 dark) {
	UIColor *(^rgb)(UInt32) = ^(UInt32 v) {
		return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0 green:((v >> 8) & 0xFF) / 255.0 blue:(v & 0xFF) / 255.0 alpha:1];
	};
	UIColor *l = rgb(light), *d = rgb(dark);
	return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
		return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? d : l;
	}];
}

static UIColor *TTXAccentColor(void)     { return TTXDynamicColor(0x0A59F7, 0x317AF7); }
static UIColor *TTXBackgroundColor(void) { return TTXDynamicColor(0xF1F3F5, 0x000000); }
static UIColor *TTXCardColor(void)       { return TTXDynamicColor(0xFFFFFF, 0x202224); }

static UIColor *TTXColorFromHex(NSString *hex) {
	unsigned int v = 0;
	[[NSScanner scannerWithString:[hex stringByReplacingOccurrencesOfString:@"#" withString:@""]] scanHexInt:&v];
	return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0 green:((v >> 8) & 0xFF) / 255.0 blue:(v & 0xFF) / 255.0 alpha:1];
}

// Row icon: a white SF Symbol on a rounded, softly lit color tile.
static UIImage *TTXIcon(NSString *symbol, UIColor *color) {
	UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
	UIImage *glyph = [[UIImage systemImageNamed:symbol withConfiguration:config] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
	if (!glyph) return nil;

	const CGFloat side = 29;
	UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
	return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
		CGRect rect = CGRectMake(0, 0, side, side);
		UIBezierPath *tile = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:8.5];
		[color setFill];
		[tile fill];

		[tile addClip];
		CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
		NSArray *colors = @[(id)[UIColor colorWithWhite:1 alpha:0.22].CGColor, (id)[UIColor colorWithWhite:1 alpha:0].CGColor];
		CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
		CGContextDrawLinearGradient(ctx.CGContext, gradient, CGPointZero, CGPointMake(0, side), 0);
		CGGradientRelease(gradient);
		CGColorSpaceRelease(space);

		CGSize s = glyph.size;
		[glyph drawInRect:CGRectMake((side - s.width) / 2, (side - s.height) / 2, s.width, s.height)];
	}];
}

@implementation TTXRootListController

#pragma mark - Specifiers

- (NSArray *)specifiers {
	if (!_specifiers) {
		TTXLoadStrings();
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
		[self localizeSpecifiers:_specifiers];
	}
	return _specifiers;
}

// Root.plist holds string keys; swap them for the chosen language and attach the row icons.
- (void)localizeSpecifiers:(NSArray<PSSpecifier *> *)specifiers {
	for (PSSpecifier *spec in specifiers) {
		if (spec.name.length) spec.name = L(spec.name);
		NSString *footer = [spec propertyForKey:@"footerText"];
		if (footer) [spec setProperty:L(footer) forKey:@"footerText"];

		// Lists filled at runtime (file names etc.) set "dynamicTitles" so they are left alone.
		if (spec.titleDictionary.count && ![[spec propertyForKey:@"dynamicTitles"] boolValue]) {
			NSMutableDictionary *titles = [NSMutableDictionary dictionary];
			[spec.titleDictionary enumerateKeysAndObjectsUsingBlock:^(id value, NSString *title, BOOL *stop) {
				titles[value] = L(title);
			}];
			spec.titleDictionary = titles;
		}

		NSString *symbol = [spec propertyForKey:@"symbol"];
		if (symbol) {
			UIImage *icon = TTXIcon(symbol, TTXColorFromHex([spec propertyForKey:@"symbolColor"] ?: @"#0A59F7"));
			if (icon) [spec setProperty:icon forKey:@"iconImage"];
		}
	}
}

// Every switch also goes into the notification state, which is what TikTok actually reads.
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
	[super setPreferenceValue:value specifier:specifier];
	TTXPublishPrefs();
	[[UISelectionFeedbackGenerator new] selectionChanged];
}

#pragma mark - Appearance

- (void)viewDidLoad {
	[super viewDidLoad];
	TTXMigrateOldPrefs();
	// The state is lost on reboot: opening Settings writes it again.
	TTXPublishPrefs();
	// Scoped to this controller so the rest of Settings keeps its own look.
	[UISwitch appearanceWhenContainedInInstancesOfClasses:@[[self class]]].onTintColor = TTXAccentColor();
	[UISlider appearanceWhenContainedInInstancesOfClasses:@[[self class]]].minimumTrackTintColor = TTXAccentColor();
	[self applyLanguage];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	CFPreferencesAppSynchronize(kPrefsDomain);
	[self reloadSpecifiers];
	self.table.backgroundColor = TTXBackgroundColor();
	self.table.tintColor = TTXAccentColor();
}

- (void)applyLanguage {
	TTXLoadStrings();
	self.title = @"TikTokX";
	self.table.tableHeaderView = [self headerView];
	self.table.tableFooterView = [self footerView];
	self.navigationItem.rightBarButtonItem = [self languageButton];
}

- (UIBarButtonItem *)languageButton {
	NSString *current = TTXLanguage();
	NSMutableArray *actions = [NSMutableArray array];
	__weak typeof(self) weakSelf = self;
	for (NSString *lang in TTXLanguages()) {
		UIAction *action = [UIAction actionWithTitle:TTXLanguageName(lang) image:nil identifier:nil handler:^(UIAction *a) {
			[weakSelf setLanguage:lang];
		}];
		action.state = [lang isEqualToString:current] ? UIMenuElementStateOn : UIMenuElementStateOff;
		[actions addObject:action];
	}
	UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"globe"] style:UIBarButtonItemStylePlain target:nil action:nil];
	item.menu = [UIMenu menuWithTitle:L(@"LANGUAGE") children:actions];
	item.tintColor = TTXAccentColor();
	return item;
}

- (void)setLanguage:(NSString *)lang {
	CFPreferencesSetAppValue(kLanguageKey, (__bridge CFStringRef)lang, kPrefsDomain);
	CFPreferencesAppSynchronize(kPrefsDomain);
	[self applyLanguage];
	_specifiers = nil;
	[self reloadSpecifiers];
}

// A full-width table header/footer holding one rounded card: an image beside a column of text lines.
// The card follows the table's layout margins so it lines up with the inset-grouped rows.
- (UIView *)cardContainerWithHeight:(CGFloat)height insets:(UIEdgeInsets)insets image:(UIImage *)image side:(CGFloat)side imageOnRight:(BOOL)imageOnRight lines:(NSArray<UILabel *> *)lines {
	UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, height)];
	container.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	container.preservesSuperviewLayoutMargins = YES;

	UIView *card = [UIView new];
	card.backgroundColor = TTXCardColor();
	card.layer.cornerRadius = 20;
	card.layer.cornerCurve = kCACornerCurveContinuous;
	card.translatesAutoresizingMaskIntoConstraints = NO;
	[container addSubview:card];

	UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
	imageView.translatesAutoresizingMaskIntoConstraints = NO;

	UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:lines];
	text.axis = UILayoutConstraintAxisVertical;
	text.spacing = 3;

	UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:imageOnRight ? @[text, imageView] : @[imageView, text]];
	row.alignment = UIStackViewAlignmentCenter;
	row.spacing = 14;
	row.translatesAutoresizingMaskIntoConstraints = NO;
	[card addSubview:row];

	UILayoutGuide *margins = container.layoutMarginsGuide;
	[NSLayoutConstraint activateConstraints:@[
		[card.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
		[card.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
		[card.topAnchor constraintEqualToAnchor:container.topAnchor constant:insets.top],
		[card.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-insets.bottom],
		[imageView.widthAnchor constraintEqualToConstant:side],
		[imageView.heightAnchor constraintEqualToConstant:side],
		[row.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
		imageOnRight ? [row.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16]
		             : [row.trailingAnchor constraintLessThanOrEqualToAnchor:card.trailingAnchor constant:-16],
		[row.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
	]];
	return container;
}

- (UILabel *)labelWithText:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
	UILabel *label = [UILabel new];
	label.text = text;
	label.font = [UIFont systemFontOfSize:size weight:weight];
	label.textColor = color;
	label.numberOfLines = 0;
	return label;
}

// Top card: name and description, app icon on the right. The enable switch follows as the first row.
- (UIView *)headerView {
	NSBundle *bundle = [NSBundle bundleForClass:[self class]];
	UIImage *logo = [UIImage imageNamed:@"logo" inBundle:bundle compatibleWithTraitCollection:nil];
	return [self cardContainerWithHeight:128 insets:UIEdgeInsetsMake(16, 0, 0, 0) image:logo side:64 imageOnRight:YES lines:@[
		[self labelWithText:@"TikTokX" size:20 weight:UIFontWeightBold color:[UIColor labelColor]],
		[self labelWithText:L(@"HEADER_TAGLINE") size:13 weight:UIFontWeightRegular color:[UIColor secondaryLabelColor]],
	]];
}

// Bottom card: author logo, app name, version and copyright.
- (UIView *)footerView {
	NSBundle *bundle = [NSBundle bundleForClass:[self class]];
	UIImage *avatar = [UIImage imageNamed:@"avatar" inBundle:bundle compatibleWithTraitCollection:nil];
	return [self cardContainerWithHeight:136 insets:UIEdgeInsetsMake(8, 0, 32, 0) image:avatar side:56 imageOnRight:NO lines:@[
		[self labelWithText:@"TikTokX" size:16 weight:UIFontWeightSemibold color:[UIColor labelColor]],
		[self labelWithText:[NSString stringWithFormat:L(@"VERSION_FORMAT"), @TWEAK_VERSION] size:13 weight:UIFontWeightRegular color:[UIColor secondaryLabelColor]],
		[self labelWithText:L(@"COPYRIGHT") size:13 weight:UIFontWeightRegular color:[UIColor secondaryLabelColor]],
	]];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
	cell.backgroundColor = TTXCardColor();
	cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];

	// Action rows read as regular navigation rows; only destructive ones stay red.
	PSSpecifier *spec = [cell isKindOfClass:[PSTableCell class]] ? ((PSTableCell *)cell).specifier : nil;
	if (spec.cellType == PSButtonCell) {
		BOOL destructive = [[spec propertyForKey:@"isDestructive"] boolValue];
		cell.textLabel.textColor = destructive ? [UIColor systemRedColor] : [UIColor labelColor];
		cell.accessoryType = destructive ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
	}
	return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
	if ([PSListController instancesRespondToSelector:_cmd]) [super tableView:tableView willDisplayHeaderView:view forSection:section];
	if (![view isKindOfClass:[UITableViewHeaderFooterView class]]) return;
	UILabel *label = ((UITableViewHeaderFooterView *)view).textLabel;
	label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
	label.textColor = [UIColor secondaryLabelColor];
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
	if ([PSListController instancesRespondToSelector:_cmd]) [super tableView:tableView willDisplayFooterView:view forSection:section];
	if (![view isKindOfClass:[UITableViewHeaderFooterView class]]) return;
	UILabel *label = ((UITableViewHeaderFooterView *)view).textLabel;
	label.font = [UIFont systemFontOfSize:12];
	label.textColor = [UIColor secondaryLabelColor];
}

#pragma mark - Helpers for actions

- (void)showMessage:(NSString *)message {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"TikTokX" message:message preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:L(@"OK") style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Actions
// TikTokX has no button rows yet; PSButtonCell actions would go here.

@end
