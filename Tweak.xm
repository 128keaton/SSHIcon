//
//  SSH Icon
//
//  Copyright © 2017 Sticktron. All rights reserved.
//

#import "common.h"
#import <Headers/LSStatusBarItem.h>
#import <Headers/LSStatusBarClient.h>
#import <dlfcn.h>
#import <notify.h>

#import <stdio.h>
#import <fcntl.h>
#import <utmpx.h>


@interface SpringBoard : UIApplication
@end

@interface SpringBoard (SSHIcon)
- (void)_sshicon_startUpdating;
- (void)_sshicon_stopUpdating;
- (void)_sshicon_update;
- (BOOL)_sshicon_isConnected;
@end


static LSStatusBarItem *sshIconItem;

static BOOL enabled;
static StatusBarAlignment alignment;
static NSString *iconStyle;

static NSTimer *updateTimer;
static float updateInterval = 5.0f;


static void loadSettings() {
	HBLogDebug(@"loadSettings()");
	
	NSDictionary *settings = nil;
	CFPreferencesAppSynchronize(kPrefsAppID);
	CFArrayRef keyList = CFPreferencesCopyKeyList(kPrefsAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	if (!keyList) {
		HBLogDebug(@"No keylist (no user settings or error.)");
	} else {
		settings = (NSDictionary *)CFBridgingRelease(CFPreferencesCopyMultiple(keyList, kPrefsAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
		HBLogDebug(@"Got user settings: %@", ONE_LINER(settings));
		CFRelease(keyList);
	}
	
	// apply user settings or defaults
	enabled = settings[@"Enabled"] ? [settings[@"Enabled"] boolValue] : YES;
	alignment = (settings[@"Alignment"] && [settings[@"Alignment"] isEqualToString:@"Left"]) ? StatusBarAlignmentLeft : StatusBarAlignmentRight;
	iconStyle = settings[@"IconStyle"] ? settings[@"IconStyle"] : @"Boxed";
}

// static void handleSettingsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
// 	HBLogDebug(@"***** Got Notification: %@", name);
// 	loadSettings();
// }

/*
 * Listen for "screen blanking" notifications (on/off).
 * Start or stop updating accordingly.
 */
void registerForScreenBlankingNotifications() {
	int notify_token;
	notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &notify_token, dispatch_get_main_queue(), ^(int token) {
		HBLogDebug(@"***** Got Notification >> com.apple.springboard.hasBlankedScreen");
		
		uint64_t state = UINT64_MAX;
		notify_get_state(token, &state);
		HBLogDebug(@"state = %llu", state);
		if (state == 1) { // screen has turned off
			[(SpringBoard *)[UIApplication sharedApplication] _sshicon_stopUpdating];
		} else { // screen has turned on
			[(SpringBoard *)[UIApplication sharedApplication] _sshicon_startUpdating];
		}
	});
}


//------------------------------------------------------------------------------

%hook SpringBoard

// redundant
// - (BOOL)application:(UIApplication *)application  didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
// 	%log;
// 	BOOL r = %orig;
//
// 	// start updating
// 	[self _sshicon_startUpdating];
//
// 	return r;
// }

%new
- (void)_sshicon_startUpdating {
	%log;
    updateTimer = [NSTimer timerWithTimeInterval:updateInterval target:self
		selector:@selector(_sshicon_update)
		userInfo:nil
		repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:updateTimer forMode:NSRunLoopCommonModes];
    HBLogDebug(@"Started updating SSHIcon (interval = %.2fs); timer = %@", updateInterval, updateTimer);
}

%new
- (void)_sshicon_stopUpdating {
	%log;
    if (updateTimer) {
        [updateTimer invalidate];
        updateTimer = nil;
		HBLogDebug(@"Stopped updating SSHIcon! timer = %@", updateTimer);
    } else {
		HBLogDebug(@"SSHIcon has already stopped");
	}
}

%new
- (void)_sshicon_update {
	%log;
	
	if ([self _sshicon_isConnected]) {
		sshIconItem.visible = YES;
	} else {
		sshIconItem.visible = NO;
	}
}

%new
- (BOOL)_sshicon_isConnected {
	%log;
	
	BOOL isConnected = NO;
	
	HBLogDebug(@"reading from utmpx:");
	HBLogDebug(@"====================");
	
	struct utmpx *up;
	
	setutxent();
	
	up = getutxent();
	while (up != NULL) {
		HBLogDebug(@"read a line from utmpx file...");
		HBLogDebug(@"--------------------");
		HBLogDebug(@"login name: %s\n", up->ut_user);
		HBLogDebug(@"id: %s\n", up->ut_id);
		HBLogDebug(@"tty name: %s\n", up->ut_line);
		HBLogDebug(@"pid: %d\n", (int)(up->ut_pid));
		HBLogDebug(@"host name: %s\n", up->ut_host);
		HBLogDebug(@"--------------------");
		
		// if (!strcmp(up->ut_host, "")) {
		if (up->ut_host[0]) {
			HBLogDebug(@"found a connected host: %s", up->ut_host);
			isConnected = YES;
			break;
		}
		
		up = getutxent();
	}
	
	endutxent();
	
	HBLogDebug(@"isConnected = %d", isConnected);
	HBLogDebug(@"====================");
	
	return isConnected;
}

%end

//------------------------------------------------------------------------------

%ctor {
	@autoreleasepool {
		NSLog(@"SSH Icon init.");
		
		// quit if libstatusbar is not installed!
		void *handle = dlopen("/Library/MobileSubstrate/DynamicLibraries/libstatusbar.dylib", RTLD_LAZY);
		if (handle == NO) {
			HBLogError(@"Can't find libstatusbar :(");
			return;
		}
		
		loadSettings();
		
		// quit if tweak is not enabled!
		if (!enabled) {
			HBLogDebug(@"disabled.");
			return;
		}
		
		// create statusbar item
		sshIconItem = [[%c(LSStatusBarItem) alloc] initWithIdentifier:@"com.sticktron.sshicon" alignment:alignment];
		sshIconItem.imageName = [NSString stringWithFormat:@"SSHIcon%@", iconStyle];
		sshIconItem.visible = NO;
		HBLogDebug(@"StatusBar item created >> %@", sshIconItem);
		
		// start hooks
		%init;
		
		// handle starting/stopping updates
		registerForScreenBlankingNotifications();

		// listen for changes to settings
		// CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
		// 	handleSettingsChanged, CFSTR("com.sticktron.sshicon.settingschanged"),
		// 	NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	}
}
