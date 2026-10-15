#!/usr/bin/env python3
"""生成普通样本并可选下载 libarchive BSD 测试样本；仅供开发验证，产品不依赖 Python/命令行工具。"""
import argparse
import binascii
import bz2
import gzip
import io
import json
import lzma
from pathlib import Path
import subprocess
import tarfile
import urllib.request
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('directory', type=Path)
parser.add_argument('--upstream', action='store_true')
args = parser.parse_args()
root = args.directory
root.mkdir(parents=True, exist_ok=True)
content = 'Archive 预览\n'.encode()
for label, compression in [('store', 0), ('deflate', 8), ('bzip2', 12), ('lzma', 14)]:
    with zipfile.ZipFile(root / (label + '.zip'), 'w', compression=compression) as archive:
        archive.writestr('目录/hello.txt', content)
        archive.writestr('empty/', b'')
with zipfile.ZipFile(root / 'zip64.zip', 'w') as archive:
    with archive.open('hello.txt', 'w', force_zip64=True) as file:
        file.write(content)
with zipfile.ZipFile(root / 'duplicates.zip', 'w') as archive:
    archive.writestr('same.txt', b'one')
    archive.writestr('same.txt', b'two')
with zipfile.ZipFile(root / 'unsafe.zip', 'w') as archive:
    archive.writestr('../escape.txt', content)
for mode, extension in [('w', 'tar'), ('w:gz', 'tgz'), ('w:bz2', 'tar.bz2'), ('w:xz', 'tar.xz')]:
    with tarfile.open(root / ('sample.' + extension), mode, format=tarfile.PAX_FORMAT) as archive:
        entry = tarfile.TarInfo('目录/hello.txt')
        entry.size = len(content)
        archive.addfile(entry, io.BytesIO(content))
        entry = tarfile.TarInfo('empty')
        entry.type = tarfile.DIRTYPE
        archive.addfile(entry)
        entry = tarfile.TarInfo('link')
        entry.type = tarfile.SYMTYPE
        entry.linkname = '/etc/passwd'
        archive.addfile(entry)
for extension, compress in [('gz', gzip.compress), ('bz2', bz2.compress), ('xz', lzma.compress)]:
    (root / ('hello.txt.' + extension)).write_bytes(compress(content))
(root / 'hello.txt').write_bytes(content)
subprocess.run(['/usr/bin/zip', '-q', '-P', 'archive-test', str(root / 'zipcrypto.zip'), 'hello.txt'], cwd=root, check=True)
subprocess.run(['/usr/bin/bsdtar', '-cf', str(root / 'sample.7z'), '--format=7zip', 'hello.txt'], cwd=root, check=True)
(root / 'damaged.zip').write_bytes((root / 'deflate.zip').read_bytes()[:45])
with zipfile.ZipFile(root / 'many.zip', 'w') as archive:
    for number in range(20000):
        archive.writestr(f'd{number // 100}/f{number}.txt', b'x')
if args.upstream:
    # 固定 tag，避免可复现样本随上游 master 变化；下载内容只保留在指定验证目录。
    base = 'https://api.github.com/repos/libarchive/libarchive/contents/libarchive/test?ref=v3.7.4'
    listing = json.load(urllib.request.urlopen(base))
    for item in listing:
        name = item['name']
        wanted = name.endswith('.uu') and any(key in name for key in [
            'test_read_format_rar.', 'test_read_format_rar5_',
            'test_read_format_rar_encryption', 'test_read_format_rar_multivolume',
            'test_read_format_7zip_encryption', 'test_read_format_7zip_lzma',
            'test_read_format_7zip_ppmd', 'test_read_format_7zip_bzip2',
            'test_read_format_zip_winzip_aes', 'test_read_format_zip_traditional_encryption'])
        if not wanted or item['size'] > 2_000_000:
            continue
        data = urllib.request.urlopen(item['download_url']).read()
        lines = data.splitlines()
        start = next(i for i, line in enumerate(lines) if line.startswith(b'begin '))
        decoded = b''.join(binascii.a2b_uu(line) for line in lines[start+1:] if line != b'end')
        (root / name[:-3]).write_bytes(decoded)
    (root / 'UPSTREAM-LICENSE').write_bytes(urllib.request.urlopen('https://raw.githubusercontent.com/libarchive/libarchive/v3.7.4/COPYING').read())
print(root)
