#import "AstroBridge.h"
#include "AstroCore.hpp"
@implementation ASCancelToken { @public std::atomic<bool> _flag; }
- (instancetype)init {if((self=[super init]))_flag.store(false);return self;}
- (void)cancel {_flag.store(true);}
- (BOOL)isCancelled {return _flag.load();}
@end
static astra::Analysis unpack(NSDictionary *d) {
    astra::Analysis a;
    for(NSArray *p in d[@"stars"])a.stars.push_back({[p[0] doubleValue],[p[1] doubleValue],[p[2] doubleValue],[p[3] doubleValue]});return a;
}
@implementation AstroBridge
+ (NSDictionary *)analyzePixels:(NSData *)pixels width:(NSInteger)w height:(NSInteger)h skyFraction:(double)sky {
    try {
        if(w<16||h<16||pixels.length!=(NSUInteger)(w*h*16))return @{@"stars":@[],@"quality":@0};
        auto a=astra::analyze((const float *)pixels.bytes,(int)w,(int)h,sky);NSMutableArray *stars=[NSMutableArray array];
        for(auto s:a.stars)[stars addObject:@[@(s.x),@(s.y),@(s.flux),@(s.radius)]];
        return @{@"stars":stars,@"quality":@(a.quality),@"noise":@(a.noise),@"background":@(a.background)};
    }catch(...){return @{@"stars":@[],@"quality":@0};}
}
+ (NSDictionary *)alignReference:(NSDictionary *)reference source:(NSDictionary *)source scale:(double)scale {
    try{auto t=astra::liftToFullResolution(astra::align(unpack(reference),unpack(source)),scale);return @{@"a":@(t.a),@"b":@(t.b),@"tx":@(t.tx),@"ty":@(t.ty),@"matches":@(t.matches),@"rms":@(t.rms)};}
    catch(const std::exception& e){return @{@"error":[NSString stringWithUTF8String:e.what()]};}
}
+ (NSString *)stackFrames:(NSArray<NSDictionary *> *)frames width:(NSInteger)w height:(NSInteger)h mode:(NSInteger)mode sigma:(double)sigma skyFraction:(double)sky feather:(double)feather destination:(NSString *)destination token:(ASCancelToken *)token progress:(void (^)(double))progress {
    try {
        std::vector<astra::Input> inputs;
        for(NSDictionary *d in frames) {
            astra::Transform t;
            t.a=[d[@"a"] doubleValue];t.b=[d[@"b"] doubleValue];t.tx=[d[@"tx"] doubleValue];t.ty=[d[@"ty"] doubleValue];
            inputs.push_back({[d[@"path"] UTF8String],t,[d[@"weight"] doubleValue],[d[@"half"] boolValue] != NO});
        }
        astra::Settings cfg;cfg.mode=(astra::Mode)mode;cfg.sigma=sigma;cfg.skyFraction=sky;cfg.feather=feather;
        astra::stack(inputs,(int)w,(int)h,cfg,[destination UTF8String],token->_flag,[&](double p){progress(p);});return nil;
    }catch(const std::exception& e){return [NSString stringWithUTF8String:e.what()];}
}
@end
