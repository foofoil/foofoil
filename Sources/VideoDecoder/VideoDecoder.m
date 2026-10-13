#import "VideoDecoder.h"
#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

// 每条音视频流独立读取，避免视频定时等待阻塞音频预缓冲；均由单串行队列持有。
typedef struct {
    AVFormatContext *format;
    AVCodecContext *codec;
    AVFrame *frame;
    AVPacket *packet;
    int stream;
    BOOL draining;
} FVStream;
static void streamClose(FVStream *s) {
    av_frame_free(&s->frame); av_packet_free(&s->packet);
    avcodec_free_context(&s->codec); avformat_close_input(&s->format);
    memset(s, 0, sizeof(*s)); s->stream = -1;
}
static enum AVPixelFormat hardwareFormat(AVCodecContext *ctx, const enum AVPixelFormat *formats) {
    for (const enum AVPixelFormat *f = formats; *f != AV_PIX_FMT_NONE; f++)
        if (*f == AV_PIX_FMT_VIDEOTOOLBOX) return *f;
    return formats[0];
}
static int streamOpen(FVStream *s, const char *path, int index, BOOL hardware) {
    memset(s, 0, sizeof(*s)); s->stream = index;
    int r = avformat_open_input(&s->format, path, NULL, NULL);
    if (r < 0) return r;
    r = avformat_find_stream_info(s->format, NULL); if (r < 0) return r;
    AVCodecParameters *p = s->format->streams[index]->codecpar;
    const AVCodec *c = avcodec_find_decoder(p->codec_id); if (!c) return AVERROR_DECODER_NOT_FOUND;
    s->codec = avcodec_alloc_context3(c); avcodec_parameters_to_context(s->codec, p);
    s->codec->thread_count = 2;
    if (hardware && (p->codec_id == AV_CODEC_ID_H264 || p->codec_id == AV_CODEC_ID_HEVC)) {
        AVBufferRef *device = NULL;
        if (av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) >= 0) {
            s->codec->hw_device_ctx = device; s->codec->get_format = hardwareFormat;
        }
    }
    r = avcodec_open2(s->codec, c, NULL); if (r < 0) return r;
    s->frame = av_frame_alloc(); s->packet = av_packet_alloc(); return 0;
}
static int streamNext(FVStream *s) {
    for (;;) {
        int r = avcodec_receive_frame(s->codec, s->frame);
        if (r >= 0 || r == AVERROR_EOF) return r;
        if (r != AVERROR(EAGAIN)) return r;
        if (s->draining) return AVERROR_EOF;
        do { av_packet_unref(s->packet); r = av_read_frame(s->format, s->packet); }
        while (r >= 0 && s->packet->stream_index != s->stream);
        if (r < 0) { s->draining = YES; avcodec_send_packet(s->codec, NULL); }
        else { r = avcodec_send_packet(s->codec, s->packet); av_packet_unref(s->packet); if (r < 0) return r; }
    }
}
static double frameTime(FVStream *s) {
    int64_t pts = s->frame->best_effort_timestamp;
    return pts == AV_NOPTS_VALUE ? 0 : pts * av_q2d(s->format->streams[s->stream]->time_base);
}
static BOOL streamSeek(FVStream *s, double seconds) {
    if (!s->codec) return YES;
    int r = av_seek_frame(s->format, -1, (int64_t)(seconds * AV_TIME_BASE), AVSEEK_FLAG_BACKWARD);
    avcodec_flush_buffers(s->codec); av_frame_unref(s->frame); s->draining = NO; return r >= 0;
}

@interface FVPlayer : NSObject {
    FVStream _video, _audio;
    AVFormatContext *_metadata;
    AVFrame *_lastFrame;
    struct SwsContext *_scale;
    SwrContext *_resample;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    AVAudioEngine *_engine;
    AVAudioPlayerNode *_node;
    AVAudioFormat *_audioFormat;
    IOSurfaceRef _surfaces[3];
    int _surfaceIndex;
    BOOL _playing, _closed, _hasVideo, _videoEOF, _audioEOF;
    double _duration, _position, _origin, _wallStart, _audioEnd, _videoPTS;
    int _subtitleIndex;
    AVFormatContext *_subFormat;
    AVCodecContext *_subCodec;
    AVPacket *_subPacket;
    AVSubtitle _subtitle;
    BOOL _hasSubtitle;
    double _subtitleStart, _subtitleEnd;
    NSString *_path, *_failure;
    NSArray *_tracks;
    uint64_t _revision;
}
- (instancetype)initWithPath:(NSString *)path error:(NSString **)error;
- (void)close;
- (void)play;
- (void)pause;
- (BOOL)seek:(double)seconds;
- (BOOL)select:(int)index;
- (void)volume:(float)value;
- (NSDictionary *)snapshot;
@end

@implementation FVPlayer
- (instancetype)initWithPath:(NSString *)path error:(NSString **)error {
    if (!(self = [super init])) return nil;
    _path = path; _video.stream = _audio.stream = _subtitleIndex = -1;
    _queue = dispatch_queue_create("app.foofoil.video.decode", DISPATCH_QUEUE_SERIAL);
    int r = avformat_open_input(&_metadata, path.fileSystemRepresentation, NULL, NULL);
    if (r >= 0) r = avformat_find_stream_info(_metadata, NULL);
    if (r < 0) { if (error) *error = @"Cannot read video file"; [self close]; return nil; }
    _duration = _metadata->duration == AV_NOPTS_VALUE ? 0 : (double)_metadata->duration / AV_TIME_BASE;
    int v = av_find_best_stream(_metadata, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    int a = av_find_best_stream(_metadata, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    NSMutableArray *tracks = [NSMutableArray array];
    for (unsigned i = 0; i < _metadata->nb_streams; i++) {
        AVStream *s = _metadata->streams[i]; AVCodecParameters *p = s->codecpar;
        if (p->codec_type != AVMEDIA_TYPE_AUDIO && p->codec_type != AVMEDIA_TYPE_SUBTITLE) continue;
        AVDictionaryEntry *lang = av_dict_get(s->metadata, "language", NULL, 0);
        AVDictionaryEntry *title = av_dict_get(s->metadata, "title", NULL, 0);
        NSString *name = title ? @(title->value) : [NSString stringWithFormat:@"%@ · %@", lang ? @(lang->value) : @"und", @(avcodec_get_name(p->codec_id))];
        BOOL supported = avcodec_find_decoder(p->codec_id) != NULL;
        [tracks addObject:@{@"id": @(i).stringValue, @"kind": p->codec_type == AVMEDIA_TYPE_AUDIO ? @"audio" : @"subtitle", @"title": name, @"isSupported": @(supported)}];
        if (p->codec_type == AVMEDIA_TYPE_SUBTITLE && supported && (_subtitleIndex < 0 || (s->disposition & AV_DISPOSITION_DEFAULT))) _subtitleIndex = i;
    }
    _tracks = tracks;
    if (v < 0 || streamOpen(&_video, path.fileSystemRepresentation, v, YES) < 0) {
        if (error) *error = @"Unsupported video encoding"; [self close]; return nil;
    }
    if (a >= 0 && streamOpen(&_audio, path.fileSystemRepresentation, a, NO) < 0) {
        if (error) *error = @"Unsupported audio encoding"; [self close]; return nil;
    }
    _engine = [[AVAudioEngine alloc] init]; _node = [[AVAudioPlayerNode alloc] init];
    _audioFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    [_engine attachNode:_node]; [_engine connect:_node to:_engine.mainMixerNode format:_audioFormat];
    [self openSubtitle:_subtitleIndex];
    [self prepareAudio];
    [self step];
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0), 5 * NSEC_PER_MSEC, NSEC_PER_MSEC);
    __weak FVPlayer *weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ FVPlayer *player = weakSelf; if (player && player->_playing) [player step]; });
    dispatch_resume(_timer);
    return self;
}
- (void)prepareAudio {
    swr_free(&_resample);
    if (!_audio.codec) return;
    AVChannelLayout output = AV_CHANNEL_LAYOUT_STEREO;
    if (swr_alloc_set_opts2(&_resample, &output, AV_SAMPLE_FMT_FLTP, 48000,
                           &_audio.codec->ch_layout, _audio.codec->sample_fmt, _audio.codec->sample_rate, 0, NULL) < 0 || swr_init(_resample) < 0)
        _failure = @"Audio resampler initialization failed";
}
- (void)closeSubtitle {
    if (_hasSubtitle) avsubtitle_free(&_subtitle);
    _hasSubtitle = NO; av_packet_free(&_subPacket); avcodec_free_context(&_subCodec); avformat_close_input(&_subFormat);
}
- (void)openSubtitle:(int)index {
    [self closeSubtitle]; _subtitleIndex = index;
    if (index < 0) return;
    if (avformat_open_input(&_subFormat, _path.fileSystemRepresentation, NULL, NULL) < 0 || avformat_find_stream_info(_subFormat, NULL) < 0) { [self closeSubtitle]; return; }
    AVCodecParameters *p = _subFormat->streams[index]->codecpar;
    const AVCodec *codec = avcodec_find_decoder(p->codec_id);
    if (!codec) { [self closeSubtitle]; return; }
    _subCodec = avcodec_alloc_context3(codec); avcodec_parameters_to_context(_subCodec, p);
    if (avcodec_open2(_subCodec, codec, NULL) < 0) { [self closeSubtitle]; return; }
    _subPacket = av_packet_alloc();
    av_seek_frame(_subFormat, -1, (int64_t)(_position * AV_TIME_BASE), AVSEEK_FLAG_BACKWARD);
}
- (void)updateSubtitle {
    if (!_subCodec || !_subPacket) return;
    if (_hasSubtitle && _subtitleEnd > _position) return;
    if (_hasSubtitle) avsubtitle_free(&_subtitle); _hasSubtitle = NO;
    for (int count = 0; count < 10000; count++) {
        int r = av_read_frame(_subFormat, _subPacket); if (r < 0) return;
        if (_subPacket->stream_index != _subtitleIndex) { av_packet_unref(_subPacket); continue; }
        double pts = _subPacket->pts == AV_NOPTS_VALUE ? 0 : _subPacket->pts * av_q2d(_subFormat->streams[_subtitleIndex]->time_base);
        double duration = _subPacket->duration * av_q2d(_subFormat->streams[_subtitleIndex]->time_base);
        int got = 0; memset(&_subtitle, 0, sizeof(_subtitle));
        r = avcodec_decode_subtitle2(_subCodec, &_subtitle, &got, _subPacket); av_packet_unref(_subPacket);
        if (r < 0 || !got) continue;
        _subtitleStart = pts + _subtitle.start_display_time / 1000.0;
        _subtitleEnd = pts + (_subtitle.end_display_time ? _subtitle.end_display_time / 1000.0 : MAX(duration, 4));
        _hasSubtitle = YES;
        if (_subtitleEnd > _position) return;
        avsubtitle_free(&_subtitle); _hasSubtitle = NO;
    }
}
- (void)renderFrame {
    av_frame_free(&_lastFrame);
    _lastFrame = av_frame_clone(_video.frame);
    [self renderFrameSource:_video.frame];
}
- (void)renderFrameSource:(AVFrame *)source {
    if (!source) return;
    AVFrame *f = source, *download = NULL;
    if (f->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        download = av_frame_alloc();
        if (av_hwframe_transfer_data(download, f, 0) < 0) { av_frame_free(&download); _failure = @"Hardware frame transfer failed"; return; }
        f = download;
    }
    int w = f->width, h = f->height;
    _surfaceIndex = (_surfaceIndex + 1) % 3;
    IOSurfaceRef surface = _surfaces[_surfaceIndex];
    if (!surface || IOSurfaceGetWidth(surface) != w || IOSurfaceGetHeight(surface) != h) {
        if (surface) CFRelease(surface);
        surface = IOSurfaceCreate((__bridge CFDictionaryRef)@{(NSString *)kIOSurfaceWidth:@(w), (NSString *)kIOSurfaceHeight:@(h),
            (NSString *)kIOSurfaceBytesPerElement:@4, (NSString *)kIOSurfaceBytesPerRow:@(w*4), (NSString *)kIOSurfacePixelFormat:@(kCVPixelFormatType_32BGRA)});
        _surfaces[_surfaceIndex] = surface;
    }
    if (!surface) { av_frame_free(&download); return; }
    IOSurfaceLock(surface, 0, NULL);
    uint8_t *dst[] = {IOSurfaceGetBaseAddress(surface)}; int stride[] = {(int)IOSurfaceGetBytesPerRow(surface)};
    _scale = sws_getCachedContext(_scale, w, h, f->format, w, h, AV_PIX_FMT_BGRA, SWS_FAST_BILINEAR, NULL, NULL, NULL);
    if (_scale) sws_scale(_scale, (const uint8_t *const *)f->data, f->linesize, 0, h, dst, stride);
    [self drawSubtitle:dst[0] width:w height:h stride:stride[0]];
    IOSurfaceUnlock(surface, 0, NULL); av_frame_free(&download); _revision++;
}
- (void)drawSubtitle:(uint8_t *)pixels width:(int)w height:(int)h stride:(int)stride {
    if (!_hasSubtitle || _position < _subtitleStart || _position >= _subtitleEnd) return;
    for (unsigned i = 0; i < _subtitle.num_rects; i++) {
        AVSubtitleRect *r = _subtitle.rects[i];
        if (r->type == SUBTITLE_BITMAP) {
            uint32_t *palette = (uint32_t *)r->data[1];
            for (int y = 0; y < r->h; y++) for (int x = 0; x < r->w; x++) {
                int dx = r->x + x, dy = r->y + y;
                if (dx < 0 || dx >= w || dy < 0 || dy >= h) continue;
                uint32_t c = palette[r->data[0][y*r->linesize[0]+x]];
                uint8_t alpha = c >> 24; uint8_t *d = pixels + dy*stride + dx*4;
                for (int k = 0; k < 3; k++) d[k] = (((c >> (8*k)) & 255) * alpha + d[k]*(255-alpha))/255;
            }
        } else {
            NSString *text = r->ass ? @(r->ass) : (r->text ? @(r->text) : @"");
            if (r->ass) { NSArray *parts = [text componentsSeparatedByString:@","]; if (parts.count >= 9) text = [[parts subarrayWithRange:NSMakeRange(8, parts.count-8)] componentsJoinedByString:@","]; }
            text = [text stringByReplacingOccurrencesOfString:@"\\N" withString:@"\n"];
            NSRegularExpression *tags = [NSRegularExpression regularExpressionWithPattern:@"\\{[^}]*\\}" options:0 error:nil];
            text = [tags stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0,text.length) withTemplate:@""];
            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            CGContextRef ctx = CGBitmapContextCreate(pixels, w, h, 8, stride, space, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
            CGColorSpaceRelease(space); if (!ctx) continue;
            NSGraphicsContext *old = NSGraphicsContext.currentContext;
            NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
            NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init]; paragraph.alignment = NSTextAlignmentCenter;
            NSDictionary *attrs = @{NSFontAttributeName:[NSFont systemFontOfSize:MAX(18,w/42.0) weight:NSFontWeightSemibold], NSForegroundColorAttributeName:NSColor.whiteColor,
                NSStrokeColorAttributeName:NSColor.blackColor, NSStrokeWidthAttributeName:@(-3), NSParagraphStyleAttributeName:paragraph};
            NSRect box = NSMakeRect(w*0.05, h*0.06, w*0.9, h*0.25);
            NSSize size = [text boundingRectWithSize:box.size options:NSStringDrawingUsesLineFragmentOrigin attributes:attrs].size;
            box.size.height = size.height;
            [text drawWithRect:box options:NSStringDrawingUsesLineFragmentOrigin attributes:attrs];
            NSGraphicsContext.currentContext = old; CGContextRelease(ctx);
        }
    }
}
- (double)clock {
    if (!_playing) return _position;
    AVAudioTime *render = _node.lastRenderTime;
    AVAudioTime *time = render ? [_node playerTimeForNodeTime:render] : nil;
    if (_audio.codec && time && time.sampleTime >= 0) return _origin + time.sampleTime / 48000.0;
    return _origin + (CACurrentMediaTime() - _wallStart);
}
- (void)step {
    @autoreleasepool {
        if (_closed || _failure) return;
        _position = MIN(_duration, [self clock]);
        // 半秒音频上限，避免按整片长度分配内存或产生临时媒体副本。
        if (_audio.codec && _resample && !_audioEOF) {
            while (_audioEnd < _position + 0.5) {
                int r = streamNext(&_audio); if (r < 0) { _audioEOF = YES; if (r != AVERROR_EOF) _failure = @"Audio decode failed"; break; }
                double pts = frameTime(&_audio);
                int capacity = (int)av_rescale_rnd(swr_get_delay(_resample,_audio.codec->sample_rate) + _audio.frame->nb_samples,48000,_audio.codec->sample_rate,AV_ROUND_UP);
                AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_audioFormat frameCapacity:capacity];
                int n = swr_convert(_resample,(uint8_t **)buffer.floatChannelData,capacity,(const uint8_t **)_audio.frame->extended_data,_audio.frame->nb_samples);
                if (n <= 0) continue;
                double end = pts + n/48000.0;
                if (end <= _origin) continue;
                int skip = pts < _origin ? (int)((_origin-pts)*48000) : 0; skip = MIN(skip,n);
                if (skip) for (int ch=0;ch<2;ch++) memmove(buffer.floatChannelData[ch],buffer.floatChannelData[ch]+skip,(n-skip)*sizeof(float));
                buffer.frameLength = n-skip;
                AVAudioTime *at = [AVAudioTime timeWithSampleTime:MAX(0,(int64_t)((MAX(pts,_origin)-_origin)*48000)) atRate:48000];
                [_node scheduleBuffer:buffer atTime:at options:0 completionHandler:nil]; _audioEnd=end;
            }
        }
        if (!_hasVideo && !_videoEOF) {
            int r = streamNext(&_video);
            if (r < 0) { _videoEOF=YES; if (r!=AVERROR_EOF) _failure=@"Video decode failed"; }
            else { _hasVideo=YES; _videoPTS=frameTime(&_video); }
        }
        if (_hasVideo && (_videoPTS <= _position + 0.012 || !_revision)) {
            [self updateSubtitle]; [self renderFrame]; _hasVideo=NO;
        }
        if (_playing && _position >= _duration-0.01 && _videoEOF) { _playing=NO; [_node pause]; _position=_duration; }
    }
}
- (void)play { dispatch_sync(_queue, ^{
    if (self->_closed || self->_playing || self->_failure) return;
    if (self->_position >= self->_duration-0.05) [self seekInternal:0];
    NSError *error=nil;
    if (![self->_engine startAndReturnError:&error]) { self->_failure=error.localizedDescription; return; }
    self->_wallStart=CACurrentMediaTime()-(self->_position-self->_origin); self->_playing=YES; [self->_node play];
}); }
- (void)pause { dispatch_sync(_queue, ^{ self->_position=[self clock]; self->_playing=NO; [self->_node pause]; }); }
- (BOOL)seekInternal:(double)seconds {
    BOOL resume=_playing; _playing=NO; [_node stop];
    seconds=MAX(0,MIN(seconds,_duration));
    if (!streamSeek(&_video,seconds) || !streamSeek(&_audio,seconds)) return NO;
    _position=_origin=_audioEnd=seconds; _hasVideo=_videoEOF=_audioEOF=NO; _revision=0;
    [self prepareAudio]; [self openSubtitle:_subtitleIndex];
    // 回退到关键帧后丢弃目标时间之前的视频帧。
    while (streamNext(&_video)>=0) { if (frameTime(&_video)>=seconds) { _hasVideo=YES; _videoPTS=frameTime(&_video); break; } }
    [self step]; _playing=resume; _wallStart=CACurrentMediaTime(); if(resume) [_node play]; return YES;
}
- (BOOL)seek:(double)seconds { __block BOOL ok; dispatch_sync(_queue, ^{ok=[self seekInternal:seconds];});return ok; }
- (BOOL)select:(int)index {
    __block BOOL ok=NO;
    dispatch_sync(_queue, ^{
        if (index == -1) { [self openSubtitle:-1]; [self renderFrameSource:self->_lastFrame]; ok=YES; return; }
        if (index < 0 || index >= self->_metadata->nb_streams) return;
        AVCodecParameters *p=self->_metadata->streams[index]->codecpar;
        if (p->codec_type==AVMEDIA_TYPE_SUBTITLE) { [self openSubtitle:index]; [self updateSubtitle]; [self renderFrameSource:self->_lastFrame]; ok=self->_subCodec!=NULL; }
        else if(p->codec_type==AVMEDIA_TYPE_AUDIO) {
            int old=self->_audio.stream; streamClose(&self->_audio);
            if(streamOpen(&self->_audio,self->_path.fileSystemRepresentation,index,NO)<0) {
                streamClose(&self->_audio); streamOpen(&self->_audio,self->_path.fileSystemRepresentation,old,NO); return;
            }
            ok=[self seekInternal:[self clock]];
        }
    });return ok;
}
- (void)volume:(float)value { dispatch_sync(_queue, ^{self->_node.volume=MAX(0,MIN(1,value));}); }
- (NSDictionary *)snapshot {
    __block NSDictionary *result;
    dispatch_sync(_queue, ^{
        IOSurfaceRef surface=self->_surfaces[self->_surfaceIndex];
        if (self->_closed) { result=@{}; return; }
        result=@{@"volume":@(self->_node.volume), @"position":@(MIN(self->_duration,MAX(0,[self clock]))), @"duration":@(self->_duration), @"state":self->_failure?@"failed":(self->_playing?@"playing":(self->_position>=self->_duration-0.05?@"stopped":@"paused")),
            @"failureMessage":self->_failure?:@"", @"surfaceID":@(surface?IOSurfaceGetID(surface):0),
            @"width":@(self->_video.codec?self->_video.codec->width:0), @"height":@(self->_video.codec?self->_video.codec->height:0),
            @"revision":@(self->_revision), @"tracks":self->_tracks?:@[], @"selectedAudioID":@(self->_audio.stream).stringValue,
            @"selectedSubtitleID":@(self->_subtitleIndex).stringValue};
    });return result;
}
- (void)close {
    if (!_queue) return;
    dispatch_sync(_queue, ^{
        if(self->_closed)return; self->_closed=YES; self->_playing=NO;
        if(self->_timer){dispatch_source_cancel(self->_timer);self->_timer=nil;}
        [self->_node stop]; [self->_engine stop]; streamClose(&self->_video);streamClose(&self->_audio);
        [self closeSubtitle];av_frame_free(&self->_lastFrame);avformat_close_input(&self->_metadata);swr_free(&self->_resample);
        sws_freeContext(self->_scale); self->_scale=NULL;
        for(int i=0;i<3;i++)if(self->_surfaces[i]){CFRelease(self->_surfaces[i]);self->_surfaces[i]=NULL;}
    });
}
@end
void *fv_open(const char *path, char **error) {
    @autoreleasepool { NSString *message=nil; FVPlayer *p=[[FVPlayer alloc] initWithPath:@(path) error:&message];
        if(!p){if(error)*error=strdup((message?:@"Cannot open video").UTF8String);return NULL;}return (__bridge_retained void *)p; }
}
void fv_close(void *p){if(p){FVPlayer *player=(__bridge_transfer FVPlayer *)p;[player close];}}
void fv_play(void *p){[(__bridge FVPlayer *)p play];}
void fv_pause(void *p){[(__bridge FVPlayer *)p pause];}
int fv_seek(void *p,double s){return [(__bridge FVPlayer *)p seek:s];}
void fv_volume(void *p,float v){[(__bridge FVPlayer *)p volume:v];}
int fv_select(void *p,int s){return [(__bridge FVPlayer *)p select:s];}
char *fv_snapshot(void *p){@autoreleasepool{NSData *d=[NSJSONSerialization dataWithJSONObject:[(__bridge FVPlayer *)p snapshot] options:0 error:nil];return d?strndup(d.bytes,d.length):NULL;}}
void fv_free(void *p){free(p);}
