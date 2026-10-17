// Read-only bridge to Logic Pro 12.3.1 Chord ID (copied from work/logic-chord-probe/harmony_probe.m).
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

@protocol HarmonyAnalyzer
- (void)analyzeWithFile:(NSURL *)file
         beatPositions:(NSArray<NSNumber *> *)beats
     downBeatPositions:(NSArray<NSNumber *> *)downbeats
       progressHandler:(void (^)(double))progress
     completionHandler:(void (^)(NSArray *, NSError *))completion;
@end
@interface NSObject (HarmonyBridge)
+ (id<HarmonyAnalyzer>)analyzer;
- (NSInteger)type;
- (NSString *)resultString;
- (double)position;
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3) { fprintf(stderr, "usage: harmony_probe CLIP.wav GRID.json\n"); return 2; }
        // The framework looks in NSBundle.mainBundle for this resource bundle.
        // A read-only symlink next to this executable satisfies that lookup.
        if (![[NSBundle mainBundle] URLForResource:@"MAMachineLearningResources" withExtension:@"bundle"]) {
            fprintf(stderr, "resource bundle symlink missing beside executable\n"); return 3;
        }
        NSError *gridError = nil;
        NSData *gridData = [NSData dataWithContentsOfFile:@(argv[2]) options:0 error:&gridError];
        NSDictionary *grid = gridData ? [NSJSONSerialization JSONObjectWithData:gridData options:0 error:&gridError] : nil;
        if (![grid isKindOfClass:NSDictionary.class] || ![grid[@"beats"] isKindOfClass:NSArray.class] || ![grid[@"downbeats"] isKindOfClass:NSArray.class]) {
            fprintf(stderr, "invalid grid JSON\n"); return 2;
        }
        void *handle = dlopen("/Applications/Logic Pro.app/Contents/Frameworks/MAMachineLearning.framework/MAMachineLearning", RTLD_NOW | RTLD_LOCAL);
        if (!handle) { fprintf(stderr, "%s\n", dlerror()); return 3; }
        Class factory = NSClassFromString(@"MAMachineLearning.HarmonyAnalyzerFactory");
        if (!factory || ![factory respondsToSelector:@selector(analyzer)]) { fprintf(stderr, "factory missing\n"); return 4; }
        id<HarmonyAnalyzer> analyzer = [factory analyzer];
        fprintf(stderr, "analyzer=%s\n", object_getClassName(analyzer));
        if (![NSStringFromClass([(id)analyzer class]) isEqualToString:@"MAMachineLearning.HarmonyAnalyzer"] ||
            ![(id)analyzer respondsToSelector:@selector(analyzeWithFile:beatPositions:downBeatPositions:progressHandler:completionHandler:)]) {
            fprintf(stderr, "unexpected analyzer or missing method\n"); return 4;
        }
        __block BOOL done = NO;
        __block int status = 0;
        [analyzer analyzeWithFile:[NSURL fileURLWithPath:@(argv[1])]
                   beatPositions:grid[@"beats"] downBeatPositions:grid[@"downbeats"]
                 progressHandler:^(double progress) { fprintf(stderr, "progress=%.6f\n", progress); }
               completionHandler:^(NSArray *results, NSError *error) {
            if (error) { fprintf(stderr, "error=%s\n", error.description.UTF8String); status = 5; }
            NSMutableArray *rows = [NSMutableArray array];
            for (NSObject *item in results) {
                [rows addObject:@{@"type":@([item type]), @"label":[item resultString], @"position":@([item position])}];
            }
            NSData *json = [NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
            if (json) { fwrite(json.bytes, 1, json.length, stdout); puts(""); }
            dispatch_async(dispatch_get_main_queue(), ^{ done = YES; });
        }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:180];
        while (!done && deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        if (!done) { fprintf(stderr, "timeout\n"); return 6; }
        return status;
    }
}
