#import "XiangqiDocumentKitVersionFixture.h"

BOOL NXQCreateLocalFileVersion(
  NSURL *documentURL,
  NSURL *contentsURL,
  NSError * _Nullable * _Nullable error
) {
  __block NSError *coordinationError = nil;
  __block NSError *versionError = nil;
  __block NSFileVersion *version = nil;
  NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
  [coordinator coordinateWritingItemAtURL:documentURL
                                  options:NSFileCoordinatorWritingForReplacing
                                    error:&coordinationError
                               byAccessor:^(NSURL *coordinatedURL) {
    version = [NSFileVersion addVersionOfItemAtURL:coordinatedURL
                                 withContentsOfURL:contentsURL
                                           options:0
                                             error:&versionError];
  }];
  if (coordinationError != nil) {
    if (error != NULL) {
      *error = coordinationError;
    }
    return NO;
  }
  if (version == nil) {
    if (error != NULL) {
      *error = versionError;
    }
    return NO;
  }
  return YES;
}
