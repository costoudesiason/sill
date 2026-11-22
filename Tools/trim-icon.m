// trim-icon <Assets.car>: drops the app icon's pre-rendered bitmaps.
//
// actool compiles the Icon Composer file into the layered icon macOS 26 and
// later draw from (vectors, colours, the icon stack) and, for older systems,
// the same icon rendered flat at every size. Sill needs macOS 27, where
// nothing reads the bitmaps, and they are 97% of the file. actool has no
// switch for leaving them out, so this removes them through CoreUI, the
// framework that reads the file. build.sh keeps the untrimmed file if this
// fails.
#import <Foundation/Foundation.h>
#import <dlfcn.h>

struct Token { uint16_t identifier, value; };
struct KeyFormat { uint32_t tag, version, count; uint32_t identifiers[0]; };

@interface CUIRenditionKey : NSObject
- (const struct Token *)keyList;
@end

@interface CUIMutableCommonAssetStorage : NSObject
- (instancetype)initWithPath:(NSString *)path forWriting:(BOOL)writing;
- (NSArray<CUIRenditionKey *> *)allAssetKeys;
- (const struct KeyFormat *)keyFormat;
- (NSData *)assetForKey:(NSData *)key;
- (void)removeAssetForKey:(NSData *)key;
- (BOOL)writeToDiskAndCompact:(BOOL)compact;
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        if (!dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW)) return 1;
        Class storage = NSClassFromString(@"CUIMutableCommonAssetStorage");
        for (NSString *name in @[@"initWithPath:forWriting:", @"allAssetKeys", @"keyFormat", @"assetForKey:",
                                 @"removeAssetForKey:", @"writeToDiskAndCompact:"]) {
            if (![storage instancesRespondToSelector:NSSelectorFromString(name)]) return 1;
        }
        CUIMutableCommonAssetStorage *car = [[storage alloc] initWithPath:@(argv[1]) forWriting:YES];
        const struct KeyFormat *format = [car keyFormat];
        if (!car || !format) return 1;

        NSMutableArray<NSData *> *bitmaps = [NSMutableArray array];
        for (CUIRenditionKey *rendition in [car allAssetKeys]) {
            // The file's own key: one value for each attribute its format names.
            NSMutableData *key = [NSMutableData dataWithLength:format->count * sizeof(uint16_t)];
            uint16_t *values = key.mutableBytes;
            for (const struct Token *token = [rendition keyList]; token->identifier; token++) {
                for (uint32_t i = 0; i < format->count; i++) {
                    if (format->identifiers[i] == token->identifier) values[i] = token->value;
                }
            }
            // A rendition starts with a fixed header; its name is the 128 bytes at 40.
            NSData *data = [car assetForKey:key];
            if (data.length < 168) continue;
            char name[129] = {0};
            memcpy(name, (const char *)data.bytes + 40, 128);
            NSString *file = @(name) ?: @"";
            if ([file hasPrefix:@"AppIcon"] && [file hasSuffix:@".png"]) [bitmaps addObject:key];
        }
        if (bitmaps.count == 0) return 0;
        for (NSData *key in bitmaps) [car removeAssetForKey:key];
        return [car writeToDiskAndCompact:YES] ? 0 : 1;
    }
}
