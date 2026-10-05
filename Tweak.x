#import "Headers.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <substrate.h>
#import <notify.h>

static BOOL ttxBackgroundAudio = kTTXDefaultBackgroundAudio;
static BOOL ttxAutoNext = kTTXDefaultAutoNext;

// Class co the la trinh phat / feed cua TikTok (ten thay doi theo phien ban)
static NSArray<NSString *> *TTXPauseClasses(void) {
	return @[@"TTVideoEngine", @"AWENewFeedTableViewController", @"TTKMediaVideoPlayerController",
		@"TTKMediaPlayerController", @"AWEVideoPlayerController", @"AWEAVPlayerWrapper_TTVideoEngine",
		@"AWENewAwemeDetailTableViewController"];
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

// TikTok bi sandbox nen khong doc duoc plist Settings ghi o /var/mobile/Library/Preferences.
// Uu tien state cua notification (prefs bundle ghi bang notify_set_state), sau do thu
// doc plist theo duong dan tuyet doi (cfprefsd cua Dopamine cho phep), cuoi cung la mac dinh.
static BOOL TTXReadBool(NSString *key, BOOL fallback, NSUserDefaults *prefs) {
	id obj = [prefs objectForKey:key];
	return [obj respondsToSelector:@selector(boolValue)] ? [obj boolValue] : fallback;
}

static void TTXLoadPrefs(void) {
	int token;
	uint64_t state = 0;
	if (notify_register_check(kTTXPrefsChanged, &token) == NOTIFY_STATUS_OK) {
		notify_get_state(token, &state);
		notify_cancel(token);
	}
	NSString *source;
	if (state & kTTXStateValid) {
		ttxBackgroundAudio = (state & kTTXStateBackground) != 0;
		ttxAutoNext = (state & kTTXStateAutoNext) != 0;
		source = @"notify";
	} else {
		NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:
			[NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", kTTXSuite]];
		ttxBackgroundAudio = TTXReadBool(kTTXBackgroundAudio, kTTXDefaultBackgroundAudio, prefs);
		ttxAutoNext = TTXReadBool(kTTXAutoNext, kTTXDefaultAutoNext, prefs);
		source = @"plist";
	}
	NSLog(@"[TikTokX] prefs (%@): backgroundAudio=%d autoNext=%d", source, ttxBackgroundAudio, ttxAutoNext);
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
// Cong tac "Am thanh nen" trong menu nhan giu video: bam vao thi TikTok goi
// setIsEnabledForLongPressPanel:YES + addEnableScene:, va trang chu phat nen duoc.
// TikTok tu dat lai ve NO nen giu no luon bat. Tham so scene khai bao long de ARC
// khong retain (khong ro kieu that), chi chuyen tiep.
%hook AWEBackgroundAudioSettingsManager
- (BOOL)isEnabledForLongPressPanel {
	return ttxBackgroundAudio ? YES : %orig;
}

- (void)setIsEnabledForLongPressPanel:(BOOL)enabled {
	%orig(ttxBackgroundAudio ? YES : enabled);
}

- (BOOL)isEnableScene:(long)scene {
	return ttxBackgroundAudio ? YES : %orig;
}

- (BOOL)isCurrentSceneEnable:(long)scene {
	return ttxBackgroundAudio ? YES : %orig;
}

// Tu cuon sang video tiep theo khi dang phat nen (ca luc khoa man hinh)
- (BOOL)isAutoPlayEnabled {
	return ttxAutoNext ? YES : %orig;
}

- (void)setIsAutoPlayEnabled:(BOOL)enabled {
	%orig(ttxAutoNext ? YES : enabled);
}
%end

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

// Scroll view doc cao nhat dang hien (feed), khong can pagingEnabled
static UIScrollView *TTXFindFeedScrollView(UIView *view) {
	UIScrollView *best = nil;
	NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:view ?: [UIView new]];
	while (queue.count) {
		UIView *v = queue.firstObject;
		[queue removeObjectAtIndex:0];
		if (v.hidden) continue;
		if ([v isKindOfClass:[UIScrollView class]] && v.bounds.size.height > best.bounds.size.height
			&& ((UIScrollView *)v).contentSize.height > v.bounds.size.height) best = (UIScrollView *)v;
		[queue addObjectsFromArray:v.subviews];
	}
	return best;
}

// Chay tren main thread khi video lap lai luc app o nen
static void TTXScrollNextIfStuck(id player) {
	UIViewController *top = ttxVisibleFeed ?: TTXTopViewController();
	UIScrollView *sv = TTXFindFeedScrollView(top.view);
	CGFloat offset = sv.contentOffset.y;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		if (sv && fabs(sv.contentOffset.y - offset) > 1) {
			ttxLastScrollInfo = @"TikTok tu cuon (nen)";
			return;
		}
		if (!TTXTryScrollNext(player)) TTXScrollNextGeneric(player);
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
		// O nen TikTok co the tu cuon (isAutoPlayEnabled): de no lam truoc, chi cuon neu feed dung yen
		if (ttxAutoNext && !ttxAppActive) {
			orig(obj, sel, arg);
			dispatch_async(dispatch_get_main_queue(), ^{
				TTXScrollNextIfStuck(obj);
			});
			return;
		}
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

#pragma mark - Remote commands

// Man hinh khoa / Control Center: TikTok dang ky 2 nut tua (skip +-15s).
// Tat 2 nut tua, thay bang nut bai truoc / bai sau de cuon feed len / xuong.
static NSUInteger ttxRemoteNext, ttxRemotePrev;
static NSString *ttxRemoteInfo = @"-";

// Cuon feed len 1 video. Chay tren main thread.
static void TTXScrollPrevious(void) {
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (now - ttxLastScroll < 0.5) return;

	UIViewController *feed = ttxVisibleFeed;
	if (feed && (!feed.view.window || feed.presentedViewController)) feed = nil;
	for (NSString *name in @[@"scrollToPreviousVideo", @"scrollToPrevVideo"]) {
		SEL sel = NSSelectorFromString(name);
		if (![feed respondsToSelector:sel]) continue;
		ttxLastScroll = now;
		((void (*)(id, SEL))objc_msgSend)(feed, sel);
		ttxRemoteInfo = [NSString stringWithFormat:@"len: %@ -%@", NSStringFromClass([feed class]), name];
		return;
	}

	UIViewController *top = feed ?: TTXTopViewController();
	UIScrollView *sv = TTXFindPagedFeed(top.view) ?: TTXFindFeedScrollView(top.view);
	CGFloat h = sv.bounds.size.height;
	if (!sv || h < 1) {
		ttxRemoteInfo = @"len: khong tim thay feed";
		return;
	}
	CGFloat prev = (round(sv.contentOffset.y / h) - 1) * h;
	if (prev < -sv.contentInset.top - 1) return; // dang o video dau
	ttxLastScroll = now;
	ttxRemoteInfo = [NSString stringWithFormat:@"len: %@ (scroll view)", NSStringFromClass([sv class])];
	[sv setContentOffset:CGPointMake(sv.contentOffset.x, prev) animated:YES];
	// Mot so feed chi phat video moi khi nguoi dung tu vuot xong
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		if ([sv.delegate respondsToSelector:@selector(scrollViewDidEndDecelerating:)]) {
			[sv.delegate scrollViewDidEndDecelerating:sv];
		}
	});
}

// MRMediaRemoteCommand: nextTrack=4, previousTrack=5, skipForward=17, skipBackward=18.
// TikTok co the dung command center rieng (khong phai sharedCommandCenter), vd. tren CarPlay,
// nen nhan dien command theo loai thay vi so sanh con tro. Tra ve 1 = xuong, -1 = len, 0 = khac.
static int TTXRemoteDirection(MPRemoteCommand *cmd) {
	MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
	if (cmd == center.nextTrackCommand || cmd == center.skipForwardCommand) return 1;
	if (cmd == center.previousTrackCommand || cmd == center.skipBackwardCommand) return -1;
	@try {
		NSInteger type = [[cmd valueForKey:@"mediaRemoteCommandType"] integerValue];
		if (type == 4 || type == 17) return 1;
		if (type == 5 || type == 18) return -1;
	} @catch (NSException *e) {}
	return 0;
}

static NSCountedSet *ttxRemoteWrapped;

// Moi command co the co nhieu target (cua TikTok + cua tweak) nen chong cuon 2 lan
static void TTXRemoteScroll(int direction, MPRemoteCommand *cmd) {
	static CFAbsoluteTime last;
	CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
	if (now - last < 0.3) return;
	last = now;
	NSString *source = NSStringFromClass(object_getClass(cmd));
	if (direction > 0) {
		ttxRemoteNext++;
		if (!TTXTryScrollNext(nil)) TTXScrollNextGeneric(nil);
		ttxRemoteInfo = [NSString stringWithFormat:@"xuong tu %@: %@", source, ttxLastScrollInfo];
	} else {
		ttxRemotePrev++;
		TTXScrollPrevious();
		ttxRemoteInfo = [NSString stringWithFormat:@"tu %@, %@", source, ttxRemoteInfo];
	}
}

// Thay handler cua nut bai truoc/bai sau/tua bang lenh cuon feed
static MPRemoteCommandHandlerStatus (^TTXWrapHandler(MPRemoteCommand *cmd, MPRemoteCommandHandlerStatus (^handler)(MPRemoteCommandEvent *)))(MPRemoteCommandEvent *) {
	TTXCount(ttxRemoteWrapped, cmd);
	__weak MPRemoteCommand *weakCmd = cmd;
	return ^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
		MPRemoteCommand *c = weakCmd ?: event.command;
		int direction = TTXRemoteDirection(c);
		if (!direction) return handler ? handler(event) : MPRemoteCommandHandlerStatusCommandFailed;
		if ([NSThread isMainThread]) TTXRemoteScroll(direction, c);
		else dispatch_async(dispatch_get_main_queue(), ^{ TTXRemoteScroll(direction, c); });
		return MPRemoteCommandHandlerStatusSuccess;
	};
}

%hook MPRemoteCommand
- (id)addTargetWithHandler:(MPRemoteCommandHandlerStatus (^)(MPRemoteCommandEvent *))handler {
	if (!TTXRemoteDirection(self)) return %orig;
	return %orig(TTXWrapHandler(self, handler));
}

- (void)addTarget:(id)target action:(SEL)action {
	if (!TTXRemoteDirection(self)) {
		%orig;
		return;
	}
	[self addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
		return MPRemoteCommandHandlerStatusSuccess;
	}];
}
%end

// TikTok co the bat lai nut tua khi doi video: luon giu tat de hien nut bai truoc / bai sau
%hook MPSkipIntervalCommand
- (void)setEnabled:(BOOL)enabled {
	%orig(NO);
}
%end

// Chay tren main thread
static void TTXSetupRemoteCommands(void) {
	MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
	center.skipForwardCommand.enabled = NO;
	center.skipBackwardCommand.enabled = NO;

	static BOOL added;
	if (!added) {
		added = YES;
		// Handler duoc hook MPRemoteCommand thay bang lenh cuon
		MPRemoteCommandHandlerStatus (^noop)(MPRemoteCommandEvent *) = ^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
			return MPRemoteCommandHandlerStatusSuccess;
		};
		[center.nextTrackCommand addTargetWithHandler:noop];
		[center.previousTrackCommand addTargetWithHandler:noop];
	}
	center.nextTrackCommand.enabled = YES;
	center.previousTrackCommand.enabled = YES;
}

#pragma mark - Background switches

// Trang tim kiem phat nen duoc, trang chu thi khong: tim cong tac phat nen cua TikTok.
// Getter BOOL co chu "background": ten mang nghia cam (pause/stop/disable...) -> NO,
// mang nghia cho phep (play/support/enable/allow/can) -> YES. Chi khi bat nhac nen.
static NSMutableArray<NSString *> *ttxBgSwitches;
// Class co ten lien quan den tu cuon (nut "Tu dong cuon" trong menu nhan giu)
static NSMutableArray<NSString *> *ttxAutoScrollClasses;

static void TTXForceBackgroundGetters(Class cls) {
	unsigned int count = 0;
	Method *methods = class_copyMethodList(cls, &count);
	for (unsigned int i = 0; i < count; i++) {
		Method method = methods[i];
		SEL sel = method_getName(method);
		NSString *lower = NSStringFromSelector(sel).lowercaseString;
		if (![lower containsString:@"background"] || method_getNumberOfArguments(method) != 2) continue;
		char ret[8] = {0};
		method_getReturnType(method, ret, sizeof(ret));
		if (!(ret[0] == 'B' || ret[0] == 'c')) continue;

		BOOL (^has)(NSArray *) = ^BOOL(NSArray *words) {
			for (NSString *w in words) {
				if ([lower containsString:w]) return YES;
			}
			return NO;
		};
		if (has(@[@"ignore", @"color", @"cancel"])) continue;
		BOOL value;
		if (has(@[@"pause", @"stop", @"disable", @"forbid"])) {
			value = NO;
		} else if (has(@[@"play", @"support", @"enable", @"allow", @"can"])) {
			value = YES;
		} else {
			[ttxBgSwitches addObject:[NSString stringWithFormat:@"%@ -%@ (giu nguyen)", NSStringFromClass(cls), NSStringFromSelector(sel)]];
			continue;
		}

		__block BOOL (*orig)(id, SEL) = NULL;
		IMP repl = imp_implementationWithBlock(^BOOL(id obj) {
			if (ttxBackgroundAudio) return value;
			return orig(obj, sel);
		});
		MSHookMessageEx(cls, sel, repl, (IMP *)&orig);
		[ttxBgSwitches addObject:[NSString stringWithFormat:@"%@ -%@ = %@", NSStringFromClass(cls), NSStringFromSelector(sel), value ? @"YES" : @"NO"]];
	}
	free(methods);
}

// Class cua cac nut trong menu nhan giu (tu cuon, xoa man hinh). Moi nut la mot
// AWEShareBaseChannel nhu TTKBackgroundAudioChannel.
static BOOL TTXIsFeatureClass(NSString *name) {
	// Bo qua class cua Live
	if ([name hasPrefix:@"IESLive"] || [name hasPrefix:@"IESMT"] || [name hasPrefix:@"GBL"]) return NO;
	for (NSString *kw in @[@"AutoScroll", @"AutoPlayNext", @"AutoSlide", @"AutoNext",
		@"ClearScreen", @"ClearMode", @"CleanMode", @"ClearDisplay", @"CleanScreen", @"PureMode"]) {
		if ([name containsString:kw]) return YES;
	}
	if (![name hasSuffix:@"Channel"]) return NO;
	for (NSString *kw in @[@"Clear", @"Clean", @"Pure", @"AutoPlay", @"Scroll"]) {
		if ([name containsString:kw]) return YES;
	}
	return NO;
}

// Class trong app co ten lien quan den phat nen (chi doc ten, khong realize toan bo class)
static void TTXScanBackgroundClasses(void) {
	NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSetWithArray:TTXPauseClasses()];
	NSString *bundlePath = [NSBundle mainBundle].bundlePath;
	NSUInteger matched = 0;
	for (uint32_t img = 0; img < _dyld_image_count() && matched < 30; img++) {
		const char *imagePath = _dyld_get_image_name(img);
		if (!imagePath || ![@(imagePath) hasPrefix:bundlePath]) continue;
		unsigned int count = 0;
		const char **classNames = objc_copyClassNamesForImage(imagePath, &count);
		for (unsigned int i = 0; i < count && matched < 30; i++) {
			NSString *name = @(classNames[i]);
			if ([name containsString:@"BackgroundPlay"] || [name containsString:@"PlayInBackground"]
				|| [name containsString:@"BackgroundAudio"] || [name containsString:@"BGPlay"]) {
				[names addObject:name];
				matched++;
			} else if (ttxAutoScrollClasses.count < 30 && TTXIsFeatureClass(name)) {
				[ttxAutoScrollClasses addObject:name];
			}
		}
		free(classNames);
	}
	[ttxBgSwitches addObject:[NSString stringWithFormat:@"Class phat nen: %lu", (unsigned long)matched]];
	for (NSString *name in names) {
		Class cls = NSClassFromString(name);
		if (!cls) continue;
		if (![TTXPauseClasses() containsObject:name]) [ttxBgSwitches addObject:name];
		TTXForceBackgroundGetters(cls);
	}
}

#pragma mark - Background audio components

// Co che phat nen chinh thuc cua TikTok: trang chu dung TTKFeedBackgroundAudioComponent,
// man chi tiet (tim kiem, phat nen duoc) dung TTKFeedDetailBackgroundAudioComponent.
// Theo doi moi method (o ca foreground) de so sanh hai ben.
static NSArray<NSString *> *TTXAudioComponentClasses(void) {
	return @[@"TTKFeedBackgroundAudioComponent", @"TTKFeedDetailBackgroundAudioComponent", @"TTKFeedBackgroundAudioTask",
		@"AWEBackgroundAudioSettingsManager", @"TTKBackgroundAudioChannel", @"GBLBackgroundPlaybackModeModel"];
}

static NSCountedSet *ttxTraceCalls;

static void TTXTrace(NSString *key) {
	@synchronized (ttxTraceCalls) {
		[ttxTraceCalls addObject:key];
	}
}

static void TTXTraceClass(NSString *className) {
	Class cls = NSClassFromString(className);
	if (!cls) return;
	unsigned int count = 0;
	Method *methods = class_copyMethodList(cls, &count);
	for (unsigned int i = 0; i < count; i++) {
		Method method = methods[i];
		SEL sel = method_getName(method);
		NSString *name = NSStringFromSelector(sel);
		if ([name hasPrefix:@"."] || [name isEqualToString:@"dealloc"]) continue;
		char ret[8] = {0}, arg[8] = {0};
		method_getReturnType(method, ret, sizeof(ret));
		unsigned int nargs = method_getNumberOfArguments(method);
		if (nargs == 3) method_getArgumentType(method, 2, arg, sizeof(arg));
		NSString *key = [NSString stringWithFormat:@"%@ -%@", className, name];

		if ((ret[0] == 'B' || ret[0] == 'c') && nargs == 2) {
			__block BOOL (*orig)(id, SEL) = NULL;
			IMP repl = imp_implementationWithBlock(^BOOL(id obj) {
				BOOL result = orig(obj, sel);
				TTXTrace([NSString stringWithFormat:@"%@=%d", key, result]);
				return result;
			});
			MSHookMessageEx(cls, sel, repl, (IMP *)&orig);
		} else if (ret[0] == 'v' && nargs == 2) {
			__block void (*orig)(id, SEL) = NULL;
			IMP repl = imp_implementationWithBlock(^(id obj) {
				TTXTrace(key);
				orig(obj, sel);
			});
			MSHookMessageEx(cls, sel, repl, (IMP *)&orig);
		} else if (ret[0] == 'v' && nargs == 3 && arg[0] == '@') {
			__block void (*orig)(id, SEL, id) = NULL;
			IMP repl = imp_implementationWithBlock(^(id obj, id a) {
				TTXTrace(key);
				orig(obj, sel, a);
			});
			MSHookMessageEx(cls, sel, repl, (IMP *)&orig);
		} else if (ret[0] == 'v' && nargs == 3 && arg[0] && strchr("BcCsSiIlLqQ", arg[0])) {
			__block void (*orig)(id, SEL, long) = NULL;
			IMP repl = imp_implementationWithBlock(^(id obj, long a) {
				TTXTrace([NSString stringWithFormat:@"%@(%ld)", key, a & 0xff]);
				orig(obj, sel, a);
			});
			MSHookMessageEx(cls, sel, repl, (IMP *)&orig);
		}
	}
	free(methods);
}

// Liet ke day du method (instance va class) kem kieu tra ve
static NSString *TTXFullMethodDump(NSString *className) {
	Class cls = NSClassFromString(className);
	if (!cls) return [NSString stringWithFormat:@"%@: (khong co class)", className];
	NSMutableArray *parts = [NSMutableArray array];
	for (int meta = 0; meta < 2; meta++) {
		Class target = meta ? object_getClass(cls) : cls;
		unsigned int count = 0;
		Method *methods = class_copyMethodList(target, &count);
		for (unsigned int i = 0; i < count && parts.count < 80; i++) {
			NSString *name = NSStringFromSelector(method_getName(methods[i]));
			if ([name hasPrefix:@"."]) continue;
			char ret[8] = {0};
			method_getReturnType(methods[i], ret, sizeof(ret));
			[parts addObject:[NSString stringWithFormat:@"%@%@(%c)", meta ? @"+" : @"", name, ret[0]]];
		}
		free(methods);
	}
	return [NSString stringWithFormat:@"%@ (%@): %@", className, NSStringFromClass(class_getSuperclass(cls)), [parts componentsJoinedByString:@" "]];
}

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

static NSString *TTXDiagnosticReport(void) {
	NSDictionary *info = [NSBundle mainBundle].infoDictionary;
	NSMutableArray *lines = [NSMutableArray array];
	[lines addObject:[NSString stringWithFormat:@"TikTokX 1.0.17 | TikTok %@ (%@) | iOS %@",
		info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"], [UIDevice currentDevice].systemVersion]];
	[lines addObject:[NSString stringWithFormat:@"Prefs: nhacNen=%d autoNext=%d", ttxBackgroundAudio, ttxAutoNext]];
	[lines addObject:[NSString stringWithFormat:@"Loop: %@ | autoNext=%lu (lan cuoi: %@)", TTXDescribeCounts(ttxLoopCalls), (unsigned long)ttxAutoNextHits, ttxLastScrollInfo]];
	[lines addObject:[NSString stringWithFormat:@"Remote: xuong=%lu len=%lu (%@) | wrap: %@", (unsigned long)ttxRemoteNext, (unsigned long)ttxRemotePrev, ttxRemoteInfo, TTXDescribeCounts(ttxRemoteWrapped)]];
	[lines addObject:@"--- Goi tren class tinh nang ---"];
	[lines addObject:TTXDescribeCounts(ttxTraceCalls)];
	[lines addObject:@"--- Class tu cuon / xoa man hinh ---"];
	for (NSString *name in ttxAutoScrollClasses) [lines addObject:TTXFullMethodDump(name)];
	return [lines componentsJoinedByString:@"\n"];
}

// Chi ghi vao syslog, khong hien popup
static void TTXLogDiagnostics(void) {
	NSLog(@"[TikTokX]\n%@", TTXDiagnosticReport());
}

%ctor {
	TTXLoadPrefs();
	NSLog(@"[TikTokX] loaded in %@", [NSBundle mainBundle].bundleIdentifier);
	ttxPauseCalls = [NSCountedSet set];
	ttxPauseBlocked = [NSCountedSet set];
	ttxLoopCalls = [NSCountedSet set];
	ttxRemoteWrapped = [NSCountedSet set];
	ttxInstalled = [NSMutableArray array];

	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, TTXPrefsChanged,
		CFSTR(kTTXPrefsChanged), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
		ttxAppActive = NO;
		TTXConfigureAudioSession();
		TTXSetupRemoteCommands();
	}];
	[nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
		TTXPlayInBackground();
	}];
	[nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
		ttxAppActive = YES;
	}];

	// Class cua TikTok nam trong binary chinh, da load khi %ctor chay
	[nc addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
		TTXSetupRemoteCommands();
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			TTXLogDiagnostics();
		});
	}];
	// Ghi bao cao moi lan quay lai tu nen
	[nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			TTXLogDiagnostics();
		});
	}];

	for (NSString *name in TTXPauseClasses()) TTXHookBackgroundClass(name);
	for (NSString *name in TTXLoopClasses()) TTXHookLoop(name);

	ttxDisplaySel = NSSelectorFromString(@"containerDidFullyDisplayWithReason:");
	ttxBoolHooks = [NSMutableArray array];
	TTXForceBool(@"AWENewFeedTableViewController", @"playInBackground", NO);
	TTXForceBool(@"TTKMediaVideoPlayerController", @"playInBackground", NO);
	TTXForceBool(@"AWENewFeedTableViewController", @"shouldIgnoreDisappearPause", YES);

	ttxBgSwitches = [NSMutableArray array];
	ttxAutoScrollClasses = [NSMutableArray array];
	TTXScanBackgroundClasses();

	ttxTraceCalls = [NSCountedSet set];
	for (NSString *name in TTXAudioComponentClasses()) TTXTraceClass(name);
	for (NSString *name in ttxAutoScrollClasses) TTXTraceClass(name);

	%init;
}
