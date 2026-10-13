#import <Foundation/Foundation.h>
int main(int argc, const char **argv) {
 @autoreleasepool {
  if(argc != 2) return 2;
  NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
  printf("bundle=%s\n",bundle ? "found" : "missing");
  printf("executable=%s\n",bundle.executablePath.UTF8String ?: "(nil)");
  printf("ordinary display name=%s\n",[bundle.infoDictionary[@"CFBundleDisplayName"] UTF8String] ?: "(nil)");
  printf("localized dictionary=%s\n",bundle.localizedInfoDictionary.description.UTF8String ?: "(nil)");
  @try {
   NSMutableDictionary *item=[NSMutableDictionary new];
   // Exact sequence at Recovery Springboard 0x100004ce0..0x100004d04.
   [item setObject:bundle.localizedInfoDictionary[@"CFBundleDisplayName"] forKey:@"BundleDisplayName"];
   printf("PASS Springboard display-name lookup: %s\n",[item[@"BundleDisplayName"] UTF8String]);
   return 0;
  } @catch(NSException *exception) {
   printf("FAIL %s: %s\n",exception.name.UTF8String,exception.reason.UTF8String);
   return 1;
  }
 }
}
