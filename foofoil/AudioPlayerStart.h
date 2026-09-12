#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

// 只在 Objective-C 栈内捕获 AVFAudio 异常；不能让异常穿过 Swift 异步栈。
FOUNDATION_EXPORT BOOL FFAudioPlayerNodePlay(AVAudioPlayerNode *node,
                                            NSError * _Nullable * _Nullable error) NS_SWIFT_NOTHROW;

NS_ASSUME_NONNULL_END
