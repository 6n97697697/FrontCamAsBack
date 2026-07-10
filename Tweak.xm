/**
 * FrontCamAsBack — v6 (diagnostic)
 *
 * MINIMAL version to verify tweak injection works.
 * Just logs when loaded into any UIKit app.
 *
 * Target: iOS 16.5 / Dopamine / rootless / arm64e
 */

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <stdio.h>

#define LOG_PATH "/tmp/FrontCamAsBack.log"

static FILE *logFile = NULL;

static void FCBLog(const char *tag, const char *fmt, ...) {
    if (!logFile) return;
    va_list args;
    va_start(args, fmt);
    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    char ts[64];
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", t);
    fprintf(logFile, "[%s] [%s] ", ts, tag);
    vfprintf(logFile, fmt, args);
    fprintf(logFile, "\n");
    fflush(logFile);
    va_end(args);
}

// Minimal hook — just log that we loaded
%hook UIApplication

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    FCBLog("INIT", "=== FrontCamAsBack v6 loaded in %s ===",
           [[[NSBundle mainBundle] bundleIdentifier] UTF8String] ?: "unknown");
    return %orig;
}

%end

%ctor {
    @autoreleasepool {
        logFile = fopen(LOG_PATH, "a");
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        FCBLog("INIT", "=== v6 constructor in %s ===", [bundleID UTF8String] ?: "?");
    }
}
