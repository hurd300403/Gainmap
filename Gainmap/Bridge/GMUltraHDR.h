//
//  GMUltraHDR.h
//  GainmapCore
//
//  Obj-C++ bridge over the uhdrtool encoder core (upstream/src/encoder.cpp +
//  the vendored libultrahdr xcframework): the in-process encode path (P2).
//  Same engine, same histogram clamp math, and — by golden test — the same
//  bytes as the bundled uhdrtool CLI produced.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Gain-map clamp values computed from the HDR buffer (mirrors the CLI's
/// stderr "clamps:" readout).
@interface GMUHDRClamps : NSObject
@property (nonatomic, readonly) double peakBoost;
@property (nonatomic, readonly) double stops;
@property (nonatomic, readonly) double maxBoost;      // K
@property (nonatomic, readonly) NSInteger targetNits; // L
@end

extern NSErrorDomain const GMUltraHDRErrorDomain;

@interface GMUltraHDR : NSObject

/// Encode scenario 3: linear interleaved RGBA f16 HDR buffer (width*height*8
/// bytes) + SDR JPEG bytes (passed through untouched) -> UltraHDR JPEG bytes.
/// `cgamut`/`sgamut` are the libultrahdr gamut ints (0 Rec.709/sRGB, 1 P3,
/// 2 Rec.2020). On failure the NSError's localizedDescription carries the SAME
/// message the CLI printed after "error: " (verbatim errors).
+ (nullable NSData *)encodeHDR:(NSData *)rgbaF16
                         width:(NSInteger)width
                        height:(NSInteger)height
                       sdrJPEG:(NSData *)sdrJPEG
                        cgamut:(NSInteger)cgamut
                        sgamut:(NSInteger)sgamut
                        clamps:(GMUHDRClamps *_Nullable *_Nullable)outClamps
                         error:(NSError **)error;

/// Clamp computation alone (histogram-based, 256 KB scratch) — exposed for the
/// parity tests.
+ (GMUHDRClamps *)clampsForHDR:(NSData *)rgbaF16
                         width:(NSInteger)width
                        height:(NSInteger)height;

@end

NS_ASSUME_NONNULL_END
