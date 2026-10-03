#import "Headers.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <substrate.h>

static BOOL ttxBackgroundAudio = kTTXDefaultBackgroundAudio;
static BOOL ttxAutoNext = kTTXDefaultAutoNext;
static BOOL ttxDiagnostics = kTTXDefaultDiagnostics;

// Class co the la trinh phat / feed cua TikTok (ten thay doi theo phien ban)
static NSArray<NSString *> *TTXPauseClasses(void) {
	return @[@"TTVideoEngine", @"AWENewFeedTableViewController", @"TTKMediaVideoPlayerController",
		@"TTKMediaPlayerController", @"AWEVideoPlayerController", @"AWEAVPlayerWrapper_TTVideoEngine"];
}
static NSArray<NSString *> *TTXLoopClasses(void) {
	return @[@"TTKMediaVideoPlayerController", @"AWEVideoPlayerController", @"TTKMediaPlayerController", @"AWEPlayVideoPlayerController"];
}

// Dem hook nao duoc goi, dung cho bao cao chan doan
static NSCountedSet *ttxPauseCalls, *ttxPauseBlocked, *ttxLoopCalls;
static NSUInteger ttxAutoNextHits;
static NSMutableArray<NSString *> *ttxInstalled;

static void TTXCount(NSCountedSet *set, id obj) {
	@synchronized (set) {
		[set addObject:NSStringFromClass(object_getClass(obj))];
	}
}

static NSString *TTXDescribeCounts(NSCountedSet *set) {
	NSMutableArray *parts = [NSMutableArray array];
	@synchronized (set) {
		for (NSString *name in set) {
			[parts addObject:[NSString stringWithFormat:@"%@x%lu", name, (unsigned long)[set countForObject:name]]];
		}
	}
	return parts.count ? [parts componentsJoinedByString:@", "] : @"0";
}

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

#pragma mark - Background audio

static void TTXConfigureAudioSession(void) {
	if (!ttxBackgroundAudio) return;
	AVAudioSession *session = [AVAudioSession sharedInstance];
	[session setCategory:AVAudioSessionCategoryPlayback error:nil];
	[session setActive:YES error:nil];
}

// Hook -pause cua tung class bang block rieng (moi block giu IMP goc cua class do,
// tranh de quy khi ca class cha va class con deu bi hook)
static void TTXHookPause(NSString *className) {
	Class cls = NSClassFromString(className);
	SEL sel = @selector(pause);
	Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
	if (!method || method_getNumberOfArguments(method) != 2) return;

	__block void (*orig)(id, SEL) = NULL;
	IMP repl = imp_implementationWithBlock(^(id obj) {
		if (!ttxAppActive) {
			TTXCount(ttxPauseCalls, obj);
			if (ttxBackgroundAudio) {
				TTXCount(ttxPauseBlocked, obj);
				return;
			}
		}
		orig(obj, sel);
	});
	MSHookMessageEx(cls, sel, repl, (IMP *)&orig);
	[ttxInstalled addObject:[NSString stringWithFormat:@"%@ -pause", className]];
}

#pragma mark - Auto next

static __weak UIViewController *ttxVisibleFeed;
static CFAbsoluteTime ttxLastScroll;

static UIView *TTXPlayerView(id player) {
	for (NSString *name in @[@"view", @"playerView", @"containerView"]) {
		SEL sel = NSSelectorFromString(name);
		if (![player respondsToSelector:sel]) continue;
		id view = ((id (*)(id, SEL))objc_msgSend)(player, sel);
		if ([view isKindOfClass:[UIView class]]) return view;
	}
	return nil;
}

// Cuon feed sang video tiep theo neu player vua phat het la video dang hien tren feed
static BOOL TTXTryScrollNext(id player) {
	UIViewController *feed = ttxVisibleFeed;
	if (!feed || !feed.view.window || feed.presentedViewController) return NO;
	if (![feed respondsToSelector:@selector(scrollToNextVideo)]) return NO;

	UIView *playerView = TTXPlayerView(player);
	if (playerView && ![playerView isDescendantOfView:feed.view]) return NO;

	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (now - ttxLastScroll < 1.0) return YES;
	ttxLastScroll = now;
	ttxAutoNextHits++;
	dispatch_async(dispatch_get_main_queue(), ^{
		[(AWENewFeedTableViewController *)feed scrollToNextVideo];
	});
	return YES;
}

static void TTXHookLoop(NSString *className) {
	Class cls = NSClassFromString(className);
	SEL sel = @selector(playerWillLoopPlaying:);
	Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
	if (!method || method_getNumberOfArguments(method) != 3) return;

	__block void (*orig)(id, SEL, id) = NULL;
	IMP repl = imp_implementationWithBlock(^(id obj, id arg) {
		TTXCount(ttxLoopCalls, obj);
		if (ttxAutoNext && TTXTryScrollNext(obj)) return;
		orig(obj, sel, arg);
	});
	MSHookMessageEx(cls, sel, repl, (IMP *)&orig);
	[ttxInstalled addObject:[NSString stringWithFormat:@"%@ -playerWillLoopPlaying:", className]];
}

%hook AWENewFeedTableViewController
- (void)viewDidAppear:(BOOL)animated {
	%orig;
	ttxVisibleFeed = self;
}

- (void)viewWillDisappear:(BOOL)animated {
	%orig;
	if (ttxVisibleFeed == self) ttxVisibleFeed = nil;
}
%end

#pragma mark - Diagnostics

// Liet ke method lien quan cua cac class dang nghi ngo
static NSString *TTXMethodDump(NSString *className) {
	Class cls = NSClassFromString(className);
	if (!cls) return [NSString stringWithFormat:@"%@: (khong co class)", className];
	NSArray *keywords = @[@"pause", @"Pause", @"loop", @"Loop", @"Background", @"background", @"ResignActive", @"resignActive", @"finish", @"Finish", @"NextVideo"];
	NSMutableArray *found = [NSMutableArray array];
	unsigned int count = 0;
	Method *methods = class_copyMethodList(cls, &count);
	for (unsigned int i = 0; i < count && found.count < 25; i++) {
		NSString *sel = NSStringFromSelector(method_getName(methods[i]));
		for (NSString *kw in keywords) {
			if ([sel containsString:kw]) {
				[found addObject:sel];
				break;
			}
		}
	}
	free(methods);
	return [NSString stringWithFormat:@"%@ (%@): %@", className, NSStringFromClass(class_getSuperclass(cls)), [found componentsJoinedByString:@" "]];
}

static NSString *TTXDiagnosticReport(void) {
	NSDictionary *info = [NSBundle mainBundle].infoDictionary;
	NSMutableArray *lines = [NSMutableArray array];
	[lines addObject:[NSString stringWithFormat:@"TikTokX 1.0.3 | TikTok %@ (%@) | iOS %@",
		info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"], [UIDevice currentDevice].systemVersion]];
	[lines addObject:[NSString stringWithFormat:@"Prefs: nhacNen=%d autoNext=%d", ttxBackgroundAudio, ttxAutoNext]];
	[lines addObject:[NSString stringWithFormat:@"Feed dang hien: %@", ttxVisibleFeed ? @"co" : @"khong"]];
	[lines addObject:[NSString stringWithFormat:@"AudioSession: %@", [AVAudioSession sharedInstance].category]];
	[lines addObject:[NSString stringWithFormat:@"Loop: %@ | autoNext=%lu", TTXDescribeCounts(ttxLoopCalls), (unsigned long)ttxAutoNextHits]];
	[lines addObject:[NSString stringWithFormat:@"Pause khi o nen: %@", TTXDescribeCounts(ttxPauseCalls)]];
	[lines addObject:[NSString stringWithFormat:@"Pause da chan: %@", TTXDescribeCounts(ttxPauseBlocked)]];
	[lines addObject:@"--- Hook da cai ---"];
	[lines addObjectsFromArray:ttxInstalled];
	[lines addObject:@"--- Method ---"];
	NSMutableOrderedSet *classes = [NSMutableOrderedSet orderedSetWithArray:TTXPauseClasses()];
	[classes addObjectsFromArray:TTXLoopClasses()];
	for (NSString *name in classes) {
		[lines addObject:TTXMethodDump(name)];
	}
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
	ttxPauseCalls = [NSCountedSet set];
	ttxPauseBlocked = [NSCountedSet set];
	ttxLoopCalls = [NSCountedSet set];
	ttxInstalled = [NSMutableArray array];

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

	// Class cua TikTok nam trong binary chinh, da load khi %ctor chay
	[nc addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			TTXShowDiagnostics();
		});
	}];
	// Hien bao cao moi lan quay lai tu nen
	[nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			TTXShowDiagnostics();
		});
	}];

	for (NSString *name in TTXPauseClasses()) TTXHookPause(name);
	for (NSString *name in TTXLoopClasses()) TTXHookLoop(name);

	%init;
}
