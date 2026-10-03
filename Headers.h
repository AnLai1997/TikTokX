#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

// Preferences
#define kTTXSuite            @"com.anlai.tiktokx"
#define kTTXBackgroundAudio  @"backgroundAudio"
#define kTTXAutoNext         @"autoNext"
#define kTTXDiagnostics      @"diagnostics"
#define kTTXPrefsChanged     "com.anlai.tiktokx/prefsChanged"

// Gia tri mac dinh khi nguoi dung chua chinh trong Settings
#define kTTXDefaultBackgroundAudio YES
#define kTTXDefaultAutoNext        YES
#define kTTXDefaultDiagnostics     YES

// TikTok private classes
@interface AWEPlayVideoPlayerController : NSObject
@property (nonatomic, weak) UIViewController *container;
@end

@interface AWENewFeedTableViewController : UIViewController
- (void)scrollToNextVideo;
@end
