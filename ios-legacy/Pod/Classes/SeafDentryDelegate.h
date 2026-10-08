//
//  SeafDentryDelegate.h
//  seafile
//

#import <Foundation/Foundation.h>

@protocol SeafDentryDelegate <NSObject>
- (void)download:(id _Nullable)entry complete:(BOOL)updated;
- (void)download:(id _Nullable)entry failed:(NSError *_Nullable)error;
- (void)download:(id _Nonnull)entry progress:(float)progress;
@end
