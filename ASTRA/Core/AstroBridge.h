#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface ASCancelToken : NSObject
- (void)cancel;
- (BOOL)isCancelled;
@end
@interface AstroBridge : NSObject
+ (NSDictionary *)analyzePixels:(NSData *)pixels width:(NSInteger)width height:(NSInteger)height skyFraction:(double)skyFraction NS_SWIFT_NAME(analyze(pixels:width:height:skyFraction:));
+ (NSDictionary *)alignReference:(NSDictionary *)reference source:(NSDictionary *)source scale:(double)scale NS_SWIFT_NAME(align(reference:source:scale:));
+ (nullable NSString *)stackFrames:(NSArray<NSDictionary *> *)frames width:(NSInteger)width height:(NSInteger)height mode:(NSInteger)mode sigma:(double)sigma skyFraction:(double)skyFraction feather:(double)feather destination:(NSString *)destination token:(ASCancelToken *)token progress:(void (^)(double))progress NS_SWIFT_NAME(stack(frames:width:height:mode:sigma:skyFraction:feather:destination:token:progress:));
@end
NS_ASSUME_NONNULL_END
