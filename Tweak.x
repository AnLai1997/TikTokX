#import "Headers.h"
#import <objc/runtime.h>

static BOOL ttxBackgroundAudio = kTTXDefaultBackgroundAudio;
static BOOL ttxAutoNext = kTTXDefaultAutoNext;
static BOOL ttxDiagnostics = kTTXDefaultDiagnostics;

// Dem so lan hook duoc goi, dung cho bao cao chan doan
static NSUInteger ttxLoopHits, ttxAutoNextHits, ttxPauseBlocked;

static void TTXLoadPrefs(void) {
	NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kTTXSuite];
	[prefs registerDefaults:@{
		kTTXBackgroundAudio: @(kTTXDefaultBackgroundAudio),
		kTTXAutoNext: @(kTTXDefaultAutoNext),
		kTTXDiagnostics: @(kTTXDefaultDiagnostics),
	}];
	ttxBackgroundAudio = [prefs boolForKey:kTTXBackgroundAudio];
	ttxAutoNext = [prefs boolForKey:kTTXAutoNext];
	ttxDiagnostics = [prefs boolForKey:kTTXDiagnostics];
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
	if (ttxBackgroundAudio && !TTXAppIsActive()) {
		ttxPauseBlocked++;
		return;
	}
	%orig;
}

// Video phat het -> cuon sang video tiep theo thay vi lap lai
- (void)playerWillLoopPlaying:(id)player {
	ttxLoopHits++;
	if (ttxAutoNext) {
		UIViewController *feed = TTXFeedControllerFrom(self.container);
		if (feed) {
			ttxAutoNextHits++;
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
	if (ttxBackgroundAudio && !TTXAppIsActive()) {
		ttxPauseBlocked++;
		return;
	}
	%orig;
}
%end

#pragma mark - Diagnostics

static NSString *TTXCheckMethod(NSString *className, NSString *selName) {
	Class cls = NSClassFromString(className);
	if (!cls) return [NSString stringWithFormat:@"[X] %@ (khong co class)", className];
	BOOL has = class_getInstanceMethod(cls, NSSelectorFromString(selName)) != NULL;
	return [NSString stringWithFormat:@"[%@] %@ -%@", has ? @"OK" : @"X", className, selName];
}

// Liet ke class cua TikTok co ten / method lien quan, de tim class bi doi ten
static NSArray<NSString *> *TTXCandidateClasses(void) {
	NSArray *nameHints = @[@"PlayVideoPlayer", @"FeedTableViewController", @"VideoEngine", @"PlayerController"];
	NSArray *selHints = @[@"scrollToNextVideo", @"playerWillLoopPlaying:", @"playerDidFinishPlaying:"];
	NSMutableArray *result = [NSMutableArray array];
	unsigned int count = 0;
	Class *classes = objc_copyClassList(&count);
	for (unsigned int i = 0; i < count && result.count < 60; i++) {
		NSString *name = NSStringFromClass(classes[i]);
		if (!([name hasPrefix:@"AWE"] || [name hasPrefix:@"TTK"] || [name hasPrefix:@"TTVideo"] || [name hasPrefix:@"TIKTOK"])) continue;

		NSMutableArray *matched = [NSMutableArray array];
		unsigned int mcount = 0;
		Method *methods = class_copyMethodList(classes[i], &mcount);
		for (unsigned int m = 0; m < mcount; m++) {
			NSString *sel = NSStringFromSelector(method_getName(methods[m]));
			if ([selHints containsObject:sel]) [matched addObject:sel];
		}
		free(methods);

		BOOL nameMatch = NO;
		for (NSString *hint in nameHints) {
			if ([name containsString:hint]) nameMatch = YES;
		}
		if (matched.count) {
			[result addObject:[NSString stringWithFormat:@"%@ {%@}", name, [matched componentsJoinedByString:@", "]]];
		} else if (nameMatch) {
			[result addObject:name];
		}
	}
	free(classes);
	return result;
}

static NSString *TTXDiagnosticReport(void) {
	NSDictionary *info = [NSBundle mainBundle].infoDictionary;
	NSArray *bgModes = info[@"UIBackgroundModes"];
	NSMutableArray *lines = [NSMutableArray array];
	[lines addObject:[NSString stringWithFormat:@"TikTokX 1.0.1 | TikTok %@ (%@) | iOS %@",
		info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"], [UIDevice currentDevice].systemVersion]];
	[lines addObject:[NSString stringWithFormat:@"Bundle: %@", [NSBundle mainBundle].bundleIdentifier]];
	[lines addObject:[NSString stringWithFormat:@"Prefs: nhacNen=%d autoNext=%d", ttxBackgroundAudio, ttxAutoNext]];
	[lines addObject:[NSString stringWithFormat:@"UIBackgroundModes: %@", bgModes.count ? [bgModes componentsJoinedByString:@","] : @"(khong co)"]];
	[lines addObject:[NSString stringWithFormat:@"Dem: loop=%lu autoNext=%lu pauseChan=%lu",
		(unsigned long)ttxLoopHits, (unsigned long)ttxAutoNextHits, (unsigned long)ttxPauseBlocked]];
	[lines addObject:@"--- Hook ---"];
	[lines addObject:TTXCheckMethod(@"AWEPlayVideoPlayerController", @"playerWillLoopPlaying:")];
	[lines addObject:TTXCheckMethod(@"AWEPlayVideoPlayerController", @"pause")];
	[lines addObject:TTXCheckMethod(@"AWEPlayVideoPlayerController", @"container")];
	[lines addObject:TTXCheckMethod(@"AWENewFeedTableViewController", @"scrollToNextVideo")];
	[lines addObject:TTXCheckMethod(@"TTVideoEngine", @"pause")];
	[lines addObject:@"--- Class lien quan ---"];
	[lines addObjectsFromArray:TTXCandidateClasses()];
	return [lines componentsJoinedByString:@"\n"];
}

static void TTXShowDiagnostics(void) {
	if (!ttxDiagnostics) return;
	NSString *report = TTXDiagnosticReport();
	NSLog(@"[TikTokX]\n%@", report);

	UIWindow *window = nil;
	for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
		if (![scene isKindOfClass:[UIWindowScene class]]) continue;
		for (UIWindow *w in ((UIWindowScene *)scene).windows) {
			if (w.isKeyWindow) window = w;
		}
	}
	UIViewController *top = window.rootViewController;
	while (top.presentedViewController) top = top.presentedViewController;
	if (!top) return;

	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"TikTokX - Chan doan" message:report preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		[UIPasteboard generalPasteboard].string = report;
	}]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Dong" style:UIAlertActionStyleCancel handler:nil]];
	[top presentViewController:alert animated:YES completion:nil];
}

%ctor {
	TTXLoadPrefs();
	NSLog(@"[TikTokX] loaded in %@", [NSBundle mainBundle].bundleIdentifier);
	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, TTXPrefsChanged,
		CFSTR(kTTXPrefsChanged), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
		TTXConfigureAudioSession();
	}];

	// Hien bao cao khi mo app va moi lan quay lai tu nen
	[nc addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			TTXShowDiagnostics();
		});
	}];
	[nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			TTXShowDiagnostics();
		});
	}];

	%init;
}
