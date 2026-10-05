#import "TTXRootListController.h"
#import <notify.h>

#define kTTXSuite         CFSTR("com.anlai.tiktokx")
#define kTTXPrefsChanged  "com.anlai.tiktokx/prefsChanged"

// Bit trong state cua notification (TikTok bi sandbox nen khong doc duoc plist,
// nhung doc duoc state nay). bit8 = da ghi (doi khi them cong tac), bit1 = nhac nen, bit2 = tu cuon,
// bit3 = doi nut tua thanh bai truoc / bai sau.
#define kTTXStateValid       (1ULL << 8)
#define kTTXStateBackground  (1ULL << 1)
#define kTTXStateAutoNext    (1ULL << 2)
#define kTTXStateRemoteScroll (1ULL << 3)

static BOOL TTXPrefBool(CFStringRef key) {
	CFPropertyListRef value = CFPreferencesCopyAppValue(key, kTTXSuite);
	id obj = value ? (__bridge_transfer id)value : nil;
	return [obj respondsToSelector:@selector(boolValue)] ? [obj boolValue] : YES;
}

// Ghi gia tri hien tai vao state roi bao cho TikTok doc lai
static void TTXPublishPrefs(void) {
	CFPreferencesAppSynchronize(kTTXSuite);
	uint64_t state = kTTXStateValid;
	if (TTXPrefBool(CFSTR("backgroundAudio"))) state |= kTTXStateBackground;
	if (TTXPrefBool(CFSTR("autoNext"))) state |= kTTXStateAutoNext;
	if (TTXPrefBool(CFSTR("remoteScroll"))) state |= kTTXStateRemoteScroll;

	int token;
	if (notify_register_check(kTTXPrefsChanged, &token) == NOTIFY_STATUS_OK) {
		notify_set_state(token, state);
		notify_cancel(token);
	}
	notify_post(kTTXPrefsChanged);
}

@implementation TTXRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
		// State mat sau khi reboot: mo Settings la ghi lai
		TTXPublishPrefs();
	}
	return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
	[super setPreferenceValue:value specifier:specifier];
	TTXPublishPrefs();
}

@end
