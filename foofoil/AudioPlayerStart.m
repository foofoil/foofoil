#import "AudioPlayerStart.h"

BOOL FFAudioPlayerNodePlay(AVAudioPlayerNode *node, NSError **error) {
    @try {
        [node play];
        return YES;
    } @catch (NSException *exception) {
        // 设备重配时即使 engine.isRunning 为真，也可能没有 IO cycle。
        // 转成普通启动错误，让宿主重建引擎并在重试耗尽后释放独占租约。
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"com.foofoil.audio.player-start"
                                        code:1
                                    userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: exception.name,
                @"exceptionName": exception.name
            }];
        }
        return NO;
    }
}
