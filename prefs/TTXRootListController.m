#import "TTXRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <notify.h>

#define kTTXSuite         CFSTR("com.anlai.tiktokx")
#define kTTXPrefsChanged  "com.anlai.tiktokx/prefsChanged"
#define kTTXLanguage      @"language"

// Co trong Preferences.framework nhung header cua Theos khong khai bao
@interface PSSpecifier (TTXPrivate)
- (void)setValues:(NSArray *)values titles:(NSArray *)titles;
@end

#ifndef TTX_VERSION
#define TTX_VERSION "?"
#endif

// Bit trong state cua notification (TikTok bi sandbox nen khong doc duoc plist,
// nhung doc duoc state nay). bit9 = da ghi (doi khi them cong tac), bit1 = nhac nen, bit2 = tu cuon,
// bit3 = doi nut tua thanh bai truoc / bai sau, bit4 = an giao dien phu tren video.
#define kTTXStateValid       (1ULL << 9)
#define kTTXStateBackground  (1ULL << 1)
#define kTTXStateAutoNext    (1ULL << 2)
#define kTTXStateRemoteScroll (1ULL << 3)
#define kTTXStateClearDisplay (1ULL << 4)

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

	int token;
	if (notify_register_check(kTTXPrefsChanged, &token) == NOTIFY_STATUS_OK) {
		notify_set_state(token, state);
		notify_cancel(token);
	}
	notify_post(kTTXPrefsChanged);
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
				@"clearDisplay.info": @"Hide the buttons, caption and other overlays on top of videos. Tap the video to show them for 3 seconds.",
				@"language": @"Language",
				@"about": @"TikTokX %@\nAuthor: AnLai\nLicense: MIT\n© 2026 AnLai",
			},
			@"vi": @{
				@"backgroundAudio": @"Phát nền",
				@"backgroundAudio.info": @"Tiếp tục phát âm thanh khi rời TikTok hoặc khóa màn hình.",
				@"autoNext": @"Tự cuộn",
				@"autoNext.info": @"Tự chuyển sang video tiếp theo khi video hiện tại phát xong.",
				@"remoteScroll": @"Nút tua → Bài trước/sau",
				@"remoteScroll.info": @"Thay nút tua ±15s trên màn hình khóa và Control Center bằng nút bài trước/bài sau để cuộn feed.",
				@"clearDisplay": @"Loại bỏ yếu tố trên màn hình",
				@"clearDisplay.info": @"Ẩn các nút, chú thích và lớp giao diện khác phủ trên video. Chạm vào video để hiện lại trong 3 giây.",
				@"language": @"Ngôn ngữ",
				@"about": @"TikTokX %@\nTác giả: AnLai\nGiấy phép: MIT\n© 2026 AnLai",
			},
		};
	});
	return strings[TTXLanguage()][key] ?: strings[@"en"][key] ?: key;
}

@implementation TTXRootListController

// Moi cong tac mot nhom, mo ta ngan nam o footer ngay duoi
- (NSArray *)switchSpecifiersForKey:(NSString *)key {
	PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
	[group setProperty:TTXText([key stringByAppendingString:@".info"]) forKey:@"footerText"];

	PSSpecifier *sw = [PSSpecifier preferenceSpecifierNamed:TTXText(key) target:self
		set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
		detail:nil cell:PSSwitchCell edit:nil];
	[sw setProperty:@"com.anlai.tiktokx" forKey:@"defaults"];
	[sw setProperty:key forKey:@"key"];
	[sw setProperty:@(TTXDefaultFor(key)) forKey:@"default"];
	return @[group, sw];
}

- (NSArray *)specifiers {
	if (!_specifiers) {
		self.title = @"TikTokX";
		NSMutableArray *specs = [NSMutableArray array];
		for (NSString *key in @[@"backgroundAudio", @"autoNext", @"remoteScroll", @"clearDisplay"]) {
			[specs addObjectsFromArray:[self switchSpecifiersForKey:key]];
		}

		[specs addObject:[PSSpecifier groupSpecifierWithName:TTXText(@"language")]];
		PSSpecifier *lang = [PSSpecifier preferenceSpecifierNamed:TTXText(@"language") target:self
			set:@selector(setPreferenceValue:specifier:) get:@selector(readLanguage:)
			detail:nil cell:PSSegmentCell edit:nil];
		[lang setProperty:@"com.anlai.tiktokx" forKey:@"defaults"];
		[lang setProperty:kTTXLanguage forKey:@"key"];
		[lang setValues:@[@"en", @"vi"] titles:@[@"English", @"Tiếng Việt"]];
		[specs addObject:lang];

		PSSpecifier *about = [PSSpecifier emptyGroupSpecifier];
		[about setProperty:[NSString stringWithFormat:TTXText(@"about"), @TTX_VERSION] forKey:@"footerText"];
		[about setProperty:@(NSTextAlignmentCenter) forKey:@"footerAlignment"];
		[specs addObject:about];

		_specifiers = specs;
		// State mat sau khi reboot: mo Settings la ghi lai
		TTXPublishPrefs();
	}
	return _specifiers;
}

- (id)readLanguage:(PSSpecifier *)specifier {
	return TTXLanguage();
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
	[super setPreferenceValue:value specifier:specifier];
	if ([[specifier propertyForKey:@"key"] isEqualToString:kTTXLanguage]) {
		CFPreferencesAppSynchronize(kTTXSuite);
		[self reloadSpecifiers];
		return;
	}
	TTXPublishPrefs();
}

@end
