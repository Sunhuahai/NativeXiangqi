#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Test-only bridge for the Foundation API that Swift intentionally does not
/// import. It creates a real, local NSFileVersion under file coordination so
/// DocumentKit can exercise its production membership/hasLocalContents gate.
FOUNDATION_EXPORT BOOL NXQCreateLocalFileVersion(
  NSURL *documentURL,
  NSURL *contentsURL,
  NSError * _Nullable * _Nullable error
);

NS_ASSUME_NONNULL_END
