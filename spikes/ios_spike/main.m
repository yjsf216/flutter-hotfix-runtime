#import <Flutter/Flutter.h>
#import <UIKit/UIKit.h>
#include <limits.h>
#include <stdlib.h>
#include "../../native/patch_store_io.h"

@interface HotfixAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) FlutterEngine *engine;
@property(nonatomic, strong) FlutterBasicMessageChannel *resultChannel;
@end

@implementation HotfixAppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)options {
  NSFileManager *files = NSFileManager.defaultManager;
  // Resolve only the OS-provided base; native patch I/O still rejects symlinks.
  NSString *documents = [files URLsForDirectory:NSDocumentDirectory
                                    inDomains:NSUserDomainMask].firstObject
                           .URLByResolvingSymlinksInPath.path;
  // Foundation can preserve /var; POSIX no-follow traversal requires /private/var.
  char resolved[PATH_MAX];
  if (!realpath(documents.fileSystemRepresentation, resolved)) {
    NSLog(@"HotfixRuntime FAIL: cannot resolve application Documents directory");
    return NO;
  }
  documents = [files stringWithFileSystemRepresentation:resolved length:strlen(resolved)];
  int baseError = psio_set_app_base(documents.fileSystemRepresentation);
  if (baseError) {
    NSLog(@"HotfixRuntime FAIL: app base initialization %d", baseError);
    return NO;
  }
  NSString *root = [documents stringByAppendingPathComponent:@"hotfix"];
#if HOTFIX_DEVICE_TEST
  NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
  NSUInteger index = [args indexOfObject:@"--hotfix-case"];
  if (index != NSNotFound && index + 1 < args.count) {
    NSString *name = args[index + 1];
    if (![@[@"baseline", @"valid", @"invalid-signature", @"wrong-baseline"]
            containsObject:name]) {
      NSLog(@"HotfixRuntime FAIL: unknown test case");
      return NO;
    }
    root = [documents stringByAppendingPathComponent:
                          [@"hotfix-device/" stringByAppendingString:name]];
  }
#endif
  NSString *patch = [root stringByAppendingPathComponent:@"inbox/patch.bytecode"];
  NSString *manifest = [root stringByAppendingPathComponent:@"inbox/manifest.json"];
  NSString *store = [root stringByAppendingPathComponent:@"store"];
  NSString *result = [root stringByAppendingPathComponent:@"result.txt"];
  [files removeItemAtPath:result error:nil];
  BOOL shouldLoad = [files fileExistsAtPath:patch] ||
                    [files fileExistsAtPath:manifest] ||
                    [files fileExistsAtPath:store];
  self.engine = [[FlutterEngine alloc] initWithName:@"hotfix-runtime"];
  BOOL started = [self.engine runWithEntrypoint:nil libraryURI:nil initialRoute:nil
                               entrypointArgs:shouldLoad
                                   ? @[patch, manifest, store, @"auto"] : nil];
  if (!started) {
    NSLog(@"HotfixRuntime FAIL: Engine did not start");
    return NO;
  }
  // iOS creates the binary messenger's platform handler during Engine.run.
  self.resultChannel = [FlutterBasicMessageChannel
      messageChannelWithName:@"hotfix/runtime-smoke"
             binaryMessenger:self.engine.binaryMessenger
                       codec:FlutterStringCodec.sharedInstance];
  [self.resultChannel setMessageHandler:^(id message, FlutterReply reply) {
    if ([message isKindOfClass:NSString.class]) {
      NSError *error = nil;
      BOOL saved = [files createDirectoryAtPath:root
                   withIntermediateDirectories:YES attributes:nil error:&error];
      if (saved) saved = [message writeToFile:result atomically:YES
                                    encoding:NSUTF8StringEncoding error:&error];
      NSLog(@"HotfixRuntime %@, resultSaved=%d, error=%@", message, saved, error);
    }
    reply(nil);
  }];
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.rootViewController = [[FlutterViewController alloc]
      initWithEngine:self.engine nibName:nil bundle:nil];
  [self.window makeKeyAndVisible];
  return YES;
}
@end

int main(int argc, char **argv) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass(HotfixAppDelegate.class));
  }
}
