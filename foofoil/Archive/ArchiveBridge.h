#ifndef FOOFOIL_ARCHIVE_BRIDGE_H
#define FOOFOIL_ARCHIVE_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
// 系统 SDK 提供 libarchive.2 链接桩但不提供头文件；这里只声明使用到的稳定 C ABI。
struct archive;
struct archive_entry;
const char *archive_version_string(void);
struct archive *archive_read_new(void);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_support_filter_bzip2(struct archive *);
int archive_read_support_filter_xz(struct archive *);
int archive_read_support_format_zip(struct archive *);
int archive_read_support_format_iso9660(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_support_format_7zip(struct archive *);
int archive_read_support_format_rar(struct archive *);
int archive_read_support_format_rar5(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_add_passphrase(struct archive *, const char *);
int archive_read_open_filenames(struct archive *, const char **, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_data_skip(struct archive *);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);
const char *archive_format_name(struct archive *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
#endif
