#import "FrontCamAsBackRootListController.h"

@implementation FrontCamAsBackRootListController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.navigationItem.title = @"FrontCamAsBack";
    }
    return self;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [
            [self loadSpecifiersFromPlistName:@"Root" target:self] retain];
    }
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *path = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist",
        [specifier propertyForKey:@"defaults"]];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];
    NSString *key = [specifier propertyForKey:@"key"];
    if (prefs && prefs[key]) {
        return prefs[key];
    }
    return [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *path = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist",
        [specifier propertyForKey:@"defaults"]];
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:path]
        ?: [NSMutableDictionary dictionary];
    [prefs setObject:value forKey:[specifier propertyForKey:@"key"]];
    [prefs writeToFile:path atomically:YES];
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.frontcamasback/preferencesChanged"),
        NULL, NULL, YES);
}

@end
