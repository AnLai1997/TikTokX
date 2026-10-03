#import "Headers.h"

static BOOL ttxBackgroundAudio = kTTXDefaultBackgroundAudio;
static BOOL ttxAutoNext = kTTXDefaultAutoNext;

static void TTXLoadPrefs(void) {
	NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kTTXSuite];
	[prefs registerDefaults:@{
		kTTXBackgroundAudio: @(kTTXDefaultBackgroundAudio),
		kTTXAutoNext: @(kTTXDefaultAutoNext),
	}];
	ttxBackgroundAudio = [prefs boolForKey:kTTXBackgroundAudio];
	ttxAutoNext = [prefs boolForKey:kTTXAutoNext];
}

static void TTXPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
	TTXLoadPrefs();
}

static BOOL TTXAppIsActive(void) {
	return [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
}

// Tim view controller cua feed co the cuon sang video tiep theo
static UIViewController *TTXFeedControllerFrom(UIViewController *vc) {
	while (vc) {
		if ([vc respondsToSelector:@selector(scrollToNextVideo)]) return vc;
		vc = vc.parentViewController;
	}
	return nil;
}

#pragma mark - Background audio

static void TTXConfigureAudioSession(void) {
	if (!ttxBackgroundAudio) return;
	AVAudioSession *session = [AVAudioSession sharedInstance];
	[session setCategory:AVAudioSessionCategoryPlayback error:nil];
	[session setActive:YES error:nil];
}

%hook AWEPlayVideoPlayerController
// Chan TikTok tu pause video khi app vao nen
- (void)pause {
	if (ttxBackgroundAudio && !TTXAppIsActive()) return;
	%orig;
}

// Video phat het -> cuon sang video tiep theo thay vi lap lai
- (void)playerWillLoopPlaying:(id)player {
	if (ttxAutoNext) {
		UIViewController *feed = TTXFeedControllerFrom(self.container);
		if (feed) {
			dispatch_async(dispatch_get_main_queue(), ^{
				[(AWENewFeedTableViewController *)feed scrollToNextVideo];
			});
			return;
		}
	}
	%orig;
}
%end

%hook TTVideoEngine
- (void)pause {
	if (ttxBackgroundAudio && !TTXAppIsActive()) return;
	%orig;
}
%end

%ctor {
	TTXLoadPrefs();
	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, TTXPrefsChanged,
		CFSTR(kTTXPrefsChanged), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

	[[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification
		object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
			TTXConfigureAudioSession();
		}];

	%init;
}
