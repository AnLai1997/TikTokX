#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>

// Preferences
#define kTTXSuite            @"com.anlai.tiktokx"
#define kTTXBackgroundAudio  @"backgroundAudio"
#define kTTXAutoNext         @"autoNext"
#define kTTXPrefsChanged     "com.anlai.tiktokx/prefsChanged"

// Bit trong state cua notification kTTXPrefsChanged (prefs bundle ghi, tweak doc)
#define kTTXStateValid       (1ULL << 0)
#define kTTXStateBackground  (1ULL << 1)
#define kTTXStateAutoNext    (1ULL << 2)

// Gia tri mac dinh khi nguoi dung chua chinh trong Settings
#define kTTXDefaultBackgroundAudio YES
#define kTTXDefaultAutoNext        YES

// TikTok private classes
@interface AWEPlayVideoPlayerController : NSObject
@property (nonatomic, weak) UIViewController *container;
@end

@interface AWENewFeedTableViewController : UIViewController
- (void)scrollToNextVideo;
@end
