#import "Headers.h"
#import <objc/runtime.h>
#import <mach-o/dyld.h>

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

// Cap nhat tu notification tren main thread; hook pause co the chay o thread khac
// nen khong goi UIApplication truc tiep o do
static volatile BOOL ttxAppActive = YES;

static BOOL TTXAppIsActive(void) {
	return ttxAppActive;
}

// Tim view controller cua feed co the cuon sang video tiep theo
static UIViewController *TTXFeedControllerFrom(id obj) {
	if (![obj isKindOfClass:[UIViewController class]]) return nil;
	UIViewController *vc = obj;
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
	if (ttxAutoNext && [self respondsToSelector:@selector(container)]) {
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

// Liet ke class cua TikTok co ten lien quan, de tim class bi doi ten.
// Chi doc ten class trong binary cua app (khong realize toan bo class nhu objc_copyClassList,
// vi lam vay co the crash app lon nhu TikTok).
static NSArray<NSString *> *TTXCandidateClasses(void) {
	NSArray *nameHints = @[@"PlayVideoPlayer", @"FeedTableViewController", @"VideoEngine", @"PlayerController"];
	NSArray *selHints = @[@"scrollToNextVideo", @"playerWillLoopPlaying:", @"playerDidFinishPlaying:"];
	NSString *bundlePath = [NSBundle mainBundle].bundlePath;
	NSMutableArray *result = [NSMutableArray array];

	for (uint32_t img = 0; img < _dyld_image_count() && result.count < 60; img++) {
		const char *imagePath = _dyld_get_image_name(img);
		if (!imagePath || ![@(imagePath) hasPrefix:bundlePath]) continue;

		unsigned int count = 0;
		const char **names = objc_copyClassNamesForImage(imagePath, &count);
		for (unsigned int i = 0; i < count && result.count < 60; i++) {
			NSString *name = @(names[i]);
			BOOL nameMatch = NO;
			for (NSString *hint in nameHints) {
				if ([name containsString:hint]) nameMatch = YES;
			}
			if (!nameMatch) continue;

			NSMutableArray *matched = [NSMutableArray array];
			Class cls = objc_getClass(names[i]);
			if (cls) {
				unsigned int mcount = 0;
				Method *methods = class_copyMethodList(cls, &mcount);
				for (unsigned int m = 0; m < mcount; m++) {
					NSString *sel = NSStringFromSelector(method_getName(methods[m]));
					if ([selHints containsObject:sel]) [matched addObject:sel];
				}
				free(methods);
			}
			[result addObject:matched.count ? [NSString stringWithFormat:@"%@ {%@}", name, [matched componentsJoinedByString:@", "]] : name];
		}
		free(names);
	}
	return result;
}

static NSString *TTXDiagnosticReport(void) {
	NSDictionary *info = [NSBundle mainBundle].infoDictionary;
	NSArray *bgModes = info[@"UIBackgroundModes"];
	NSMutableArray *lines = [NSMutableArray array];
	[lines addObject:[NSString stringWithFormat:@"TikTokX 1.0.2 | TikTok %@ (%@) | iOS %@",
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
		ttxAppActive = NO;
		TTXConfigureAudioSession();
	}];
	[nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
		ttxAppActive = YES;
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
