/**
 * FrontCamAsBack v9 — absolute minimal, just log that we loaded
 */

#import <Foundation/Foundation.h>

#define LOG_PATH "/tmp/FrontCamAsBack.log"

%ctor {
    @autoreleasepool {
        FILE *f = fopen(LOG_PATH, "a");
        if (f) {
            fprintf(f, "=== v9 LOADED in %s ===\n",
                [[[NSBundle mainBundle] bundleIdentifier] UTF8String] ?: "unknown");
            fclose(f);
        }
    }
}
