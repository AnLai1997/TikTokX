#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>

// Preferences
#define kTTXSuite            @"com.tiktokx"
#define kTTXBackgroundAudio  @"backgroundAudio"
#define kTTXAutoNext         @"autoNext"
#define kTTXRemoteScroll     @"remoteScroll"
#define kTTXClearDisplay     @"clearDisplay"
#define kTTXPrefsChanged     "com.tiktokx/prefsChanged"

// Bit trong state cua notification kTTXPrefsChanged (prefs bundle ghi, tweak doc)
// Doi bit "da ghi" moi khi them cong tac de bo qua state cua ban cu
#define kTTXStateValid       (1ULL << 10)
#define kTTXStateBackground  (1ULL << 1)
#define kTTXStateAutoNext    (1ULL << 2)
#define kTTXStateRemoteScroll (1ULL << 3)
#define kTTXStateClearDisplay (1ULL << 4)

// Gia tri mac dinh khi nguoi dung chua chinh trong Settings
#define kTTXDefaultBackgroundAudio YES
#define kTTXDefaultAutoNext        YES
#define kTTXDefaultRemoteScroll    YES
#define kTTXDefaultClearDisplay    NO

// TikTok private classes
@interface AWEPlayVideoPlayerController : NSObject
@property (nonatomic, weak) UIViewController *container;
@end

@interface AWENewFeedTableViewController : UIViewController
- (void)scrollToNextVideo;
@end
