/*
 *  H.265 hardware decoder for iOS, modelled on RTCVideoDecoderH264.mm.
 *  Use of this source code is governed by a BSD-style license (WebRTC LICENSE).
 */

#import "RTCVideoDecoderH265.h"

#import <VideoToolbox/VideoToolbox.h>

#include <memory>
#include <vector>

#import "base/RTCVideoFrame.h"
#import "base/RTCVideoFrameBuffer.h"
#import "components/video_frame_buffer/RTCCVPixelBuffer.h"

#include "modules/video_coding/include/video_error_codes.h"
#include "rtc_base/logging.h"
#include "rtc_base/time_utils.h"

namespace {

struct H265DecodeParams {
  H265DecodeParams(RTCVideoDecoderCallback cb, int64_t ts)
      : callback(cb), timestamp(ts) {}
  RTCVideoDecoderCallback callback;
  int64_t timestamp;
};

struct Nalu {
  const uint8_t *data;
  size_t size;
  int type;
};

// Splits an Annex B buffer into NAL units, without their start codes.
std::vector<Nalu> ParseAnnexB(const uint8_t *buffer, size_t length) {
  std::vector<Nalu> nalus;
  size_t start = 0;
  bool found = false;
  for (size_t i = 0; i + 3 <= length;) {
    if (buffer[i] == 0 && buffer[i + 1] == 0 && buffer[i + 2] == 1) {
      if (found) {
        size_t end = i;
        if (end > start && buffer[end - 1] == 0) end--;
        if (end > start) {
          nalus.push_back({buffer + start, end - start, (buffer[start] >> 1) & 0x3F});
        }
      }
      start = i + 3;
      found = true;
      i += 3;
    } else {
      i++;
    }
  }
  if (found && length > start) {
    nalus.push_back({buffer + start, length - start, (buffer[start] >> 1) & 0x3F});
  }
  return nalus;
}

const int kNaluVps = 32;
const int kNaluSps = 33;
const int kNaluPps = 34;

// Returns a +1 format description if the buffer has VPS, SPS and PPS.
CMVideoFormatDescriptionRef CreateFormat(const std::vector<Nalu> &nalus) {
  const Nalu *vps = nullptr, *sps = nullptr, *pps = nullptr;
  for (const Nalu &nalu : nalus) {
    if (nalu.type == kNaluVps && !vps) vps = &nalu;
    if (nalu.type == kNaluSps && !sps) sps = &nalu;
    if (nalu.type == kNaluPps && !pps) pps = &nalu;
  }
  if (!vps || !sps || !pps) return nullptr;
  const uint8_t *sets[3] = {vps->data, sps->data, pps->data};
  const size_t sizes[3] = {vps->size, sps->size, pps->size};
  CMVideoFormatDescriptionRef format = nullptr;
  OSStatus status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
      kCFAllocatorDefault, 3, sets, sizes, 4, nullptr, &format);
  if (status != noErr) {
    RTC_LOG(LS_ERROR) << "Failed to create HEVC format: " << status;
    return nullptr;
  }
  return format;
}

// Returns a +1 sample buffer holding the frame's slices, length-prefixed.
CMSampleBufferRef CreateSample(const std::vector<Nalu> &nalus,
                               CMVideoFormatDescriptionRef format) {
  std::vector<uint8_t> data;
  for (const Nalu &nalu : nalus) {
    if (nalu.type == kNaluVps || nalu.type == kNaluSps || nalu.type == kNaluPps) continue;
    const uint32_t size = CFSwapInt32HostToBig(static_cast<uint32_t>(nalu.size));
    const uint8_t *prefix = reinterpret_cast<const uint8_t *>(&size);
    data.insert(data.end(), prefix, prefix + 4);
    data.insert(data.end(), nalu.data, nalu.data + nalu.size);
  }
  if (data.empty()) return nullptr;
  CMBlockBufferRef block = nullptr;
  OSStatus status = CMBlockBufferCreateWithMemoryBlock(
      kCFAllocatorDefault, nullptr, data.size(), kCFAllocatorDefault, nullptr, 0,
      data.size(), kCMBlockBufferAssureMemoryNowFlag, &block);
  if (status != kCMBlockBufferNoErr) return nullptr;
  status = CMBlockBufferReplaceDataBytes(data.data(), block, 0, data.size());
  CMSampleBufferRef sample = nullptr;
  if (status == kCMBlockBufferNoErr) {
    status = CMSampleBufferCreate(kCFAllocatorDefault, block, true, nullptr, nullptr,
                                  format, 1, 0, nullptr, 0, nullptr, &sample);
  }
  CFRelease(block);
  return status == noErr ? sample : nullptr;
}

}  // namespace

@interface RTC_OBJC_TYPE (RTCVideoDecoderH265)
() - (void)setError : (OSStatus)error;
@end

static void H265DecompressionCallback(void *decoderRef,
                                      void *params,
                                      OSStatus status,
                                      VTDecodeInfoFlags infoFlags,
                                      CVImageBufferRef imageBuffer,
                                      CMTime timestamp,
                                      CMTime duration) {
  std::unique_ptr<H265DecodeParams> decodeParams(
      reinterpret_cast<H265DecodeParams *>(params));
  if (status != noErr || !imageBuffer) {
    RTC_OBJC_TYPE(RTCVideoDecoderH265) *decoder =
        (__bridge RTC_OBJC_TYPE(RTCVideoDecoderH265) *)decoderRef;
    [decoder setError:status != noErr ? status : kVTVideoDecoderBadDataErr];
    RTC_LOG(LS_ERROR) << "Failed to decode H265 frame. Status: " << status;
    return;
  }
  RTC_OBJC_TYPE(RTCCVPixelBuffer) *frameBuffer =
      [[RTC_OBJC_TYPE(RTCCVPixelBuffer) alloc] initWithPixelBuffer:imageBuffer];
  RTC_OBJC_TYPE(RTCVideoFrame) *decodedFrame = [[RTC_OBJC_TYPE(RTCVideoFrame) alloc]
      initWithBuffer:frameBuffer
            rotation:RTCVideoRotation_0
         timeStampNs:decodeParams->timestamp * webrtc::kNumNanosecsPerMillisec];
  decodedFrame.timeStamp = decodeParams->timestamp;
  decodeParams->callback(decodedFrame);
}

@implementation RTC_OBJC_TYPE (RTCVideoDecoderH265) {
  CMVideoFormatDescriptionRef _videoFormat;
  VTDecompressionSessionRef _decompressionSession;
  RTCVideoDecoderCallback _callback;
  OSStatus _error;
}

+ (BOOL)isSupported {
  return VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
}

+ (NSArray<RTC_OBJC_TYPE(RTCVideoCodecInfo) *> *)supportedCodecs {
  if (![self isSupported]) return @[];
  return @[ [[RTC_OBJC_TYPE(RTCVideoCodecInfo) alloc]
      initWithName:@"H265"
        parameters:@{
          @"profile-id" : @"1",
          @"tier-flag" : @"0",
          @"level-id" : @"156",
          @"tx-mode" : @"SRST",
        }] ];
}

- (void)dealloc {
  [self destroyDecompressionSession];
  [self setVideoFormat:nullptr];
}

- (NSInteger)startDecodeWithNumberOfCores:(int)numberOfCores {
  return WEBRTC_VIDEO_CODEC_OK;
}

- (NSInteger)decode:(RTC_OBJC_TYPE(RTCEncodedImage) *)inputImage
        missingFrames:(BOOL)missingFrames
    codecSpecificInfo:(nullable id<RTC_OBJC_TYPE(RTCCodecSpecificInfo)>)info
         renderTimeMs:(int64_t)renderTimeMs {
  if (_error != noErr) {
    RTC_LOG(LS_WARNING) << "Last H265 frame decode failed.";
    _error = noErr;
    return WEBRTC_VIDEO_CODEC_ERROR;
  }
  const std::vector<Nalu> nalus = ParseAnnexB(
      static_cast<const uint8_t *>(inputImage.buffer.bytes), inputImage.buffer.length);

  CMVideoFormatDescriptionRef inputFormat = CreateFormat(nalus);
  if (inputFormat) {
    if (!_videoFormat || !CMFormatDescriptionEqual(inputFormat, _videoFormat)) {
      [self setVideoFormat:inputFormat];
      const int reset = [self resetDecompressionSession];
      if (reset != WEBRTC_VIDEO_CODEC_OK) {
        CFRelease(inputFormat);
        return reset;
      }
    }
    CFRelease(inputFormat);
  }
  // Returning an error makes WebRTC request a key frame with parameter sets.
  if (!_videoFormat || !_decompressionSession) return WEBRTC_VIDEO_CODEC_ERROR;

  CMSampleBufferRef sample = CreateSample(nalus, _videoFormat);
  if (!sample) return WEBRTC_VIDEO_CODEC_ERROR;

  VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression;
  auto params = std::make_unique<H265DecodeParams>(_callback, inputImage.timeStamp);
  OSStatus status = VTDecompressionSessionDecodeFrame(
      _decompressionSession, sample, flags, params.release(), nullptr);
  if ((status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr) &&
      [self resetDecompressionSession] == WEBRTC_VIDEO_CODEC_OK && _decompressionSession) {
    params = std::make_unique<H265DecodeParams>(_callback, inputImage.timeStamp);
    status = VTDecompressionSessionDecodeFrame(
        _decompressionSession, sample, flags, params.release(), nullptr);
  }
  CFRelease(sample);
  if (status != noErr) {
    RTC_LOG(LS_ERROR) << "Failed to decode H265 frame with code: " << status;
    return WEBRTC_VIDEO_CODEC_ERROR;
  }
  return WEBRTC_VIDEO_CODEC_OK;
}

- (void)setCallback:(RTCVideoDecoderCallback)callback {
  _callback = callback;
}

- (void)setError:(OSStatus)error {
  _error = error;
}

- (NSInteger)releaseDecoder {
  [self destroyDecompressionSession];
  [self setVideoFormat:nullptr];
  _callback = nullptr;
  return WEBRTC_VIDEO_CODEC_OK;
}

- (int)resetDecompressionSession {
  [self destroyDecompressionSession];
  if (!_videoFormat) return WEBRTC_VIDEO_CODEC_OK;
  NSDictionary *attributes = @{
    (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (NSString *)kCVPixelBufferPixelFormatTypeKey :
        @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
  };
  VTDecompressionOutputCallbackRecord record = {
      H265DecompressionCallback,
      (__bridge void *)self,
  };
  OSStatus status = VTDecompressionSessionCreate(
      nullptr, _videoFormat, nullptr, (__bridge CFDictionaryRef)attributes, &record,
      &_decompressionSession);
  if (status != noErr) {
    RTC_LOG(LS_ERROR) << "Failed to create H265 decompression session: " << status;
    [self destroyDecompressionSession];
    return WEBRTC_VIDEO_CODEC_ERROR;
  }
  VTSessionSetProperty(_decompressionSession, kVTDecompressionPropertyKey_RealTime,
                       kCFBooleanTrue);
  return WEBRTC_VIDEO_CODEC_OK;
}

- (void)destroyDecompressionSession {
  if (_decompressionSession) {
    VTDecompressionSessionWaitForAsynchronousFrames(_decompressionSession);
    VTDecompressionSessionInvalidate(_decompressionSession);
    CFRelease(_decompressionSession);
    _decompressionSession = nullptr;
  }
}

- (void)setVideoFormat:(CMVideoFormatDescriptionRef)videoFormat {
  if (_videoFormat == videoFormat) return;
  if (_videoFormat) CFRelease(_videoFormat);
  _videoFormat = videoFormat;
  if (_videoFormat) CFRetain(_videoFormat);
}

- (NSString *)implementationName {
  return @"VideoToolbox";
}

@end
