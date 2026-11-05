"""Adds the H.265 decoder to a jitsi/webrtc checkout. Usage: apply_patch.py <src> <dir of this script>"""
import pathlib, shutil, sys

src, here = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
codec = src / 'sdk/objc/components/video_codec'

shutil.copy(here / 'RTCVideoDecoderH265.mm', codec / 'RTCVideoDecoderH265.mm')
header = (codec / 'RTCVideoDecoderH264.h').read_text()
assert 'RTCVideoDecoderH264' in header
header = header.replace('RTCVideoDecoderH264', 'RTCVideoDecoderH265')
assert 'supportedCodecs' in header
(codec / 'RTCVideoDecoderH265.h').write_text(header)


def replace_once(path, old, new):
    text = path.read_text()
    assert text.count(old) == 1, f'{path}: {old!r} found {text.count(old)} times'
    path.write_text(text.replace(old, new))


replace_once(src / 'sdk/BUILD.gn',
             '''        "objc/components/video_codec/RTCVideoDecoderH264.mm",
''',
             '''        "objc/components/video_codec/RTCVideoDecoderH264.mm",
        "objc/components/video_codec/RTCVideoDecoderH265.h",
        "objc/components/video_codec/RTCVideoDecoderH265.mm",
''')

factory = codec / 'RTCDefaultVideoDecoderFactory.m'
replace_once(factory, '#import "RTCVideoDecoderH264.h"\n',
             '#import "RTCVideoDecoderH264.h"\n#import "RTCVideoDecoderH265.h"\n')
replace_once(factory, '''  [result
      addObjectsFromArray:[RTC_OBJC_TYPE(RTCVideoDecoderVP8) supportedCodecs]];
''', '''  [result
      addObjectsFromArray:[RTC_OBJC_TYPE(RTCVideoDecoderH265) supportedCodecs]];
  [result
      addObjectsFromArray:[RTC_OBJC_TYPE(RTCVideoDecoderVP8) supportedCodecs]];
''')
replace_once(factory, '''  } else if ([info.name isEqualToString:kRTCVideoCodecVp8Name]) {
''', '''  } else if ([info.name isEqualToString:@"H265"]) {
    return [[RTC_OBJC_TYPE(RTCVideoDecoderH265) alloc] init];
  } else if ([info.name isEqualToString:kRTCVideoCodecVp8Name]) {
''')
print('patched')
