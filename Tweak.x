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
	return @[@"TTKMediaVideoPlayerController", @"AWEVideoPlayerController", @"TTKMediaPlayerController", @"AWEPlayVideoPlayerController",
		@"TTKCommerceSearchVideoPlayerController"];
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

// Hook cac method void lien quan den pause/stop/play/background cua class player.
// Khi app o nen: dem so lan goi (cho bao cao chan doan) va chan cac method "pause..."
// de video khong bi dung. Moi block giu IMP goc cua class do nen hook ca class cha
// lan class con khong bi de quy.
static BOOL TTXIsTraceSelector(NSString *name) {
	NSString *lower = name.lowercaseString;
	for (NSString *kw in @[@"pause", @"stop", @"play", @"background", @"resignactive", @"interrupt", @"mute", @"volume", @"close"]) {
		if ([lower containsString:kw]) return YES;
	}
	return NO;
}

// Player cua video dang hien tren man hinh (de goi playInBackground khi vao nen)
static __weak id ttxCurrentPlayer;
static SEL ttxDisplaySel;

// Tra ve YES neu da chan, NO neu can goi IMP goc
static BOOL TTXBackgroundCall(id obj, SEL sel, BOOL blockable) {
	if (ttxAppActive) {
		if (sel == ttxDisplaySel) ttxCurrentPlayer = obj;
		return NO;
	}
	NSString *key = [NSString stringWithFormat:@"%@ -%@", NSStringFromClass(object_getClass(obj)), NSStringFromSelector(sel)];
	@synchronized (ttxPauseCalls) {
		[ttxPauseCalls addObject:key];
	}
	if (!blockable || !ttxBackgroundAudio) return NO;
	@synchronized (ttxPauseBlocked) {
		[ttxPauseBlocked addObject:key];
	}
	return YES;
}

static BOOL TTXHookBackgroundMethod(Class cls, Method method) {
	SEL sel = method_getName(method);
	NSString *name = NSStringFromSelector(sel);
	if (!TTXIsTraceSelector(name)) return NO;

	char ret[8] = {0};
	method_getReturnType(method, ret, sizeof(ret));
	if (ret[0] != 'v') return NO;

	// Chan ca handler "vao nen" (feed trang chu tu dung video o day)
	NSString *lower = name.lowercaseString;
	BOOL blockable = [lower hasPrefix:@"pause"] || [lower containsString:@"resignactive"] || [lower containsString:@"enterbackground"];
	unsigned int nargs = method_getNumberOfArguments(method);
	if (nargs == 2) {
		__block void (*orig)(id, SEL) = NULL;
		IMP repl = imp_implementationWithBlock(^(id obj) {
			if (TTXBackgroundCall(obj, sel, blockable)) return;
			orig(obj, sel);
		});
		MSHookMessageEx(cls, sel, repl, (IMP *)&orig);
		return YES;
	}
	if (nargs != 3) return NO;

	char arg[8] = {0};
	method_getArgumentType(method, 2, arg, sizeof(arg));
	if (arg[0] == '@') {
		__block void (*orig)(id, SEL, id) = NULL;
		IMP repl = imp_implementationWithBlock(^(id obj, id a) {
			if (TTXBackgroundCall(obj, sel, blockable)) return;
			orig(obj, sel, a);
		});
		MSHookMessageEx(cls, sel, repl, (IMP *)&orig);
		return YES;
	}
	// Tham so so nguyen / BOOL nam trong thanh ghi x2, chuyen tiep nguyen ven (arm64)
	if (arg[0] && strchr("BcCsSiIlLqQ", arg[0])) {
		__block void (*orig)(id, SEL, long) = NULL;
		IMP repl = imp_implementationWithBlock(^(id obj, long a) {
			if (TTXBackgroundCall(obj, sel, blockable)) return;
			orig(obj, sel, a);
		});
		MSHookMessageEx(cls, sel, repl, (IMP *)&orig);
		return YES;
	}
	return NO;
}

static void TTXHookBackgroundClass(NSString *className) {
	Class cls = NSClassFromString(className);
	if (!cls) return;
	NSUInteger hooked = 0;
	unsigned int count = 0;
	Method *methods = class_copyMethodList(cls, &count);
	for (unsigned int i = 0; i < count; i++) {
		if (TTXHookBackgroundMethod(cls, methods[i])) hooked++;
	}
	free(methods);
	[ttxInstalled addObject:[NSString stringWithFormat:@"%@: %lu method", className, (unsigned long)hooked]];
}

// TikTok kiem tra applicationState de tu dung / khong phat khi app khong active.
// Khi bat nhac nen va app dang o nen, bao cho TikTok la app van dang mo.
%hook UIApplication
- (UIApplicationState)applicationState {
	if (ttxBackgroundAudio && !ttxAppActive) return UIApplicationStateActive;
	return %orig;
}
%end

// TikTok co san co che phat nen (playInBackground, shouldIgnoreDisappearPause) nhung bi tat.
// Ep getter BOOL tra ve YES; onlyInBackground = chi khi app dang o nen.
static NSMutableArray<NSString *> *ttxBoolHooks;

static void TTXForceBool(NSString *className, NSString *selName, BOOL onlyInBackground) {
	Class cls = NSClassFromString(className);
	SEL sel = NSSelectorFromString(selName);
	Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
	if (!method) return;
	char ret[8] = {0};
	method_getReturnType(method, ret, sizeof(ret));
	[ttxBoolHooks addObject:[NSString stringWithFormat:@"%@ -%@ (%s)", className, selName, ret]];
	if (method_getNumberOfArguments(method) != 2 || !(ret[0] == 'B' || ret[0] == 'c')) return;

	__block BOOL (*orig)(id, SEL) = NULL;
	IMP repl = imp_implementationWithBlock(^BOOL(id obj) {
		if (ttxBackgroundAudio && (!onlyInBackground || !ttxAppActive)) return YES;
		return orig(obj, sel);
	});
	MSHookMessageEx(cls, sel, repl, (IMP *)&orig);
}

#pragma mark - Auto next

static __weak UIViewController *ttxVisibleFeed;
static CFAbsoluteTime ttxLastScroll;
static NSString *ttxLastScrollInfo = @"-";

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
		// O nen TikTok co ham cuon rieng
		SEL bgSel = NSSelectorFromString(@"scrollToNextBackgroundVideo");
		if (!ttxAppActive && [feed respondsToSelector:bgSel]) {
			((void (*)(id, SEL))objc_msgSend)(feed, bgSel);
			ttxLastScrollInfo = [NSString stringWithFormat:@"%@ (nen)", NSStringFromClass([feed class])];
			return;
		}
		[(AWENewFeedTableViewController *)feed scrollToNextVideo];
		ttxLastScrollInfo = NSStringFromClass([feed class]);
	});
	return YES;
}

// Feed dang video full man hinh (vd. ket qua tim kiem): scroll view cuon tung trang, cao gan bang man hinh
static BOOL TTXIsPagedFeed(UIScrollView *sv) {
	UIWindow *window = sv.window;
	if (!window || sv.hidden || !sv.pagingEnabled) return NO;
	CGFloat h = sv.bounds.size.height;
	return h >= window.bounds.size.height * 0.8 && sv.contentSize.height > h + 1;
}

static UIScrollView *TTXFindPagedFeed(UIView *view) {
	if ([view isKindOfClass:[UIScrollView class]] && TTXIsPagedFeed((UIScrollView *)view)) return (UIScrollView *)view;
	for (UIView *sub in view.subviews.reverseObjectEnumerator) {
		if (sub.hidden || sub.alpha < 0.01) continue;
		UIScrollView *found = TTXFindPagedFeed(sub);
		if (found) return found;
	}
	return nil;
}

static UIViewController *TTXTopViewController(void) {
	UIWindow *window = nil;
	for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
		if (![scene isKindOfClass:[UIWindowScene class]]) continue;
		for (UIWindow *w in ((UIWindowScene *)scene).windows) {
			if (w.isKeyWindow) window = w;
		}
	}
	UIViewController *top = window.rootViewController;
	while (top.presentedViewController) top = top.presentedViewController;
	return top;
}

// Cuon sang video tiep theo o feed khac trang chu. Chay tren main thread.
static void TTXScrollNextGeneric(id player) {
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (now - ttxLastScroll < 1.0) return;

	UIView *playerView = TTXPlayerView(player);
	if (playerView && !playerView.window) return; // player an / dang preload
	// Dang mo man hinh khac de len (binh luan, chia se...) thi khong cuon
	UIViewController *top = TTXTopViewController();
	if (playerView && ![playerView isDescendantOfView:top.view]) return;

	// 1. Controller chua player co san scrollToNextVideo
	for (UIResponder *r = playerView; r; r = r.nextResponder) {
		if (![r isKindOfClass:[UIViewController class]]) continue;
		UIViewController *vc = (UIViewController *)r;
		if ([vc respondsToSelector:@selector(scrollToNextVideo)]) {
			if (vc.presentedViewController) return;
			ttxLastScroll = now;
			ttxAutoNextHits++;
			ttxLastScrollInfo = NSStringFromClass([vc class]);
			[(AWENewFeedTableViewController *)vc scrollToNextVideo];
			return;
		}
	}

	// 2. Scroll view cuon tung trang chua player (hoac tren man hinh dang hien neu khong lay duoc view)
	UIScrollView *sv = nil;
	for (UIView *v = playerView.superview; v && !sv; v = v.superview) {
		if ([v isKindOfClass:[UIScrollView class]] && TTXIsPagedFeed((UIScrollView *)v)) sv = (UIScrollView *)v;
	}
	if (!sv && !playerView) sv = TTXFindPagedFeed(top.view);
	if (!sv) return;

	CGFloat h = sv.bounds.size.height;
	CGFloat next = (round(sv.contentOffset.y / h) + 1) * h;
	if (next + h > sv.contentSize.height + sv.contentInset.bottom + 1) return; // het video
	ttxLastScroll = now;
	ttxAutoNextHits++;
	ttxLastScrollInfo = [NSString stringWithFormat:@"%@ (scroll view)", NSStringFromClass([sv class])];
	[sv setContentOffset:CGPointMake(sv.contentOffset.x, next) animated:YES];
	// Mot so feed chi phat video moi khi nguoi dung tu vuot xong
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		if ([sv.delegate respondsToSelector:@selector(scrollViewDidEndDecelerating:)]) {
			[sv.delegate scrollViewDidEndDecelerating:sv];
		}
	});
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
		// Khong phai feed trang chu: de video lap lai, roi thu cuon feed dang chua player
		if (ttxAutoNext) {
			dispatch_async(dispatch_get_main_queue(), ^{
				TTXScrollNextGeneric(obj);
			});
		}
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

#pragma mark - Play in background

// Trang chu khong tu goi playInBackground khi vao nen nen trinh phat dung o tang duoi
// (khong qua pause). Goi thay TikTok tren feed va player dang hien.
static NSString *ttxPlayInBackgroundInfo = @"chua goi";

static void TTXPlayInBackground(void) {
	if (!ttxBackgroundAudio) return;
	SEL sel = NSSelectorFromString(@"playInBackground");
	NSMutableArray *called = [NSMutableArray array];
	for (id target in @[ttxVisibleFeed ?: [NSNull null], ttxCurrentPlayer ?: [NSNull null]]) {
		if (target == [NSNull null] || ![target respondsToSelector:sel]) continue;
		((void (*)(id, SEL))objc_msgSend)(target, sel);
		[called addObject:NSStringFromClass(object_getClass(target))];
	}
	ttxPlayInBackgroundInfo = called.count ? [called componentsJoinedByString:@", "] : @"khong co doi tuong";
}

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
	[lines addObject:[NSString stringWithFormat:@"TikTokX 1.0.8 | TikTok %@ (%@) | iOS %@",
		info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"], [UIDevice currentDevice].systemVersion]];
	[lines addObject:[NSString stringWithFormat:@"Prefs: nhacNen=%d autoNext=%d", ttxBackgroundAudio, ttxAutoNext]];
	[lines addObject:[NSString stringWithFormat:@"Feed dang hien: %@", ttxVisibleFeed ? @"co" : @"khong"]];
	[lines addObject:[NSString stringWithFormat:@"AudioSession: %@", [AVAudioSession sharedInstance].category]];
	[lines addObject:[NSString stringWithFormat:@"Loop: %@ | autoNext=%lu (lan cuoi: %@)", TTXDescribeCounts(ttxLoopCalls), (unsigned long)ttxAutoNextHits, ttxLastScrollInfo]];
	[lines addObject:[NSString stringWithFormat:@"Goi khi o nen: %@", TTXDescribeCounts(ttxPauseCalls)]];
	[lines addObject:[NSString stringWithFormat:@"Pause da chan: %@", TTXDescribeCounts(ttxPauseBlocked)]];
	[lines addObject:@"--- Hook da cai ---"];
	[lines addObject:[NSString stringWithFormat:@"playInBackground da goi: %@", ttxPlayInBackgroundInfo]];
	[lines addObjectsFromArray:ttxBoolHooks];
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
	[nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
		TTXPlayInBackground();
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

	for (NSString *name in TTXPauseClasses()) TTXHookBackgroundClass(name);
	for (NSString *name in TTXLoopClasses()) TTXHookLoop(name);

	ttxDisplaySel = NSSelectorFromString(@"containerDidFullyDisplayWithReason:");
	ttxBoolHooks = [NSMutableArray array];
	TTXForceBool(@"AWENewFeedTableViewController", @"playInBackground", NO);
	TTXForceBool(@"TTKMediaVideoPlayerController", @"playInBackground", NO);
	TTXForceBool(@"AWENewFeedTableViewController", @"shouldIgnoreDisappearPause", YES);

	%init;
}
