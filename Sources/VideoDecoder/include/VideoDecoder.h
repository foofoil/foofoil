#ifndef VIDEO_DECODER_H
#define VIDEO_DECODER_H
#include <stdint.h>
void *fv_open(const char *path, char **error);
void fv_close(void *player);
void fv_play(void *player);
void fv_pause(void *player);
int fv_seek(void *player, double seconds);
void fv_subtitle_delay(void *player, double seconds);
void fv_volume(void *player, float volume);
int fv_select(void *player, int stream);
// 返回 UTF-8 JSON；调用方用 fv_free 释放，任何 Objective-C 对象不跨模块边界。
char *fv_snapshot(void *player);
void fv_free(void *bytes);
#endif
