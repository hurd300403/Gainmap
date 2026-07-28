//
//  GMUltraHDR.mm
//  GainmapCore
//

#import "GMUltraHDR.h"

#include <string>
#include <vector>

#include "encoder.h"

NSErrorDomain const GMUltraHDRErrorDomain = @"com.legacylab.gainmap.uhdr";

@implementation GMUHDRClamps {
    @package
    uhdrtool::Clamps _c;
}
- (double)peakBoost { return _c.peak_boost; }
- (double)stops { return _c.stops; }
- (double)maxBoost { return _c.K; }
- (NSInteger)targetNits { return _c.L; }
@end

@implementation GMUltraHDR

+ (nullable NSData *)encodeHDR:(NSData *)rgbaF16
                         width:(NSInteger)width
                        height:(NSInteger)height
                       sdrJPEG:(NSData *)sdrJPEG
                        cgamut:(NSInteger)cgamut
                        sgamut:(NSInteger)sgamut
                        clamps:(GMUHDRClamps *_Nullable *_Nullable)outClamps
                         error:(NSError **)error {
    auto fail = [&](NSString *message) -> NSData * {
        if (error) {
            *error = [NSError errorWithDomain:GMUltraHDRErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey : message}];
        }
        return nil;
    };

    const size_t expected = (size_t)width * (size_t)height * 4 * sizeof(uint16_t);
    if (width <= 0 || height <= 0 || rgbaF16.length != expected) {
        return fail([NSString stringWithFormat:
            @"HDR buffer size %lu != expected %zu (w*h*4*2 bytes)",
            (unsigned long)rgbaF16.length, expected]);
    }

    // Zero-copy: the descriptors point straight into the NSData backings for
    // the duration of the call (both are kept alive by ARC across it).
    uhdrtool::RawF16View view;
    view.rgba_f16 = static_cast<const uint16_t *>(rgbaF16.bytes);
    view.width = (int)width;
    view.height = (int)height;

    uhdrtool::Clamps clamps = uhdrtool::computeClamps(view);
    if (outClamps) {
        GMUHDRClamps *c = [GMUHDRClamps new];
        c->_c = clamps;
        *outClamps = c;
    }

    std::vector<uint8_t> out;
    std::string err;
    if (!uhdrtool::encodeUltraHdrToMemory(view, clamps,
                                          static_cast<const uint8_t *>(sdrJPEG.bytes),
                                          sdrJPEG.length,
                                          (int)cgamut, (int)sgamut, out, err)) {
        return fail([NSString stringWithUTF8String:err.c_str()] ?: @"encode failed");
    }
    return [NSData dataWithBytes:out.data() length:out.size()];
}

+ (GMUHDRClamps *)clampsForHDR:(NSData *)rgbaF16
                         width:(NSInteger)width
                        height:(NSInteger)height {
    uhdrtool::RawF16View view;
    view.rgba_f16 = static_cast<const uint16_t *>(rgbaF16.bytes);
    view.width = (int)width;
    view.height = (int)height;
    GMUHDRClamps *c = [GMUHDRClamps new];
    c->_c = uhdrtool::computeClamps(view);
    return c;
}

@end
