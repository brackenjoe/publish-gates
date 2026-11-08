#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joe Fernandez
#
# Test for check-media-metadata.py, found beside this file. Exit 0 if every
# case passed, 1 if any failed, 2 if the fixtures could not be built.
#
#   test-check-media-metadata.sh
#
# Offline. The tool is run as `python3 -I check-media-metadata.py`. Every fixture
# is built in a mktemp -d (removed at the end), from literal bytes and with
# ffmpeg. A reason is asserted by its stable text, never by the metadata value;
# each refusal can also check that a value planted in the fixture (coordinates,
# a place name) is not in the output.
#
# Cases (a clean file is exit 0 and no output; a refusal is exit 1 and a line
# that starts with the path):
#   J1  JPEG from ffmpeg (with its Lavc COM) passes; J2 JFIF, ICC and Adobe
#       segments and NUL padding behind EOI pass
#   J3  APP1 EXIF  J4 APP1 XMP  J5 APP13 Photoshop/IPTC  J6 a second COM
#   J7  a COM that is not the Lavc stamp  J8 bytes after EOI  J9 truncated
#   P1  PNG passes; P2 tEXt Title, Software and Comment pass; P3 iTXt Title passes
#   P4  eXIf  P5 zTXt  P6 iTXt with its compression flag set
#   P7  tEXt with the keyword exif:GPSLatitude  P8 bytes after IEND
#   W1  WebP passes (plain and VP8X)  W2 EXIF chunk  W3 XMP chunk
#   W4  RIFF size that is not the file's
#   G1  GIF passes  G2 comment extension  G3 XMP application extension
#   V1  MP4 with title, comment and creation_time passes
#   V2  MP4 with a location tag  V3 MP4 with a make tag
#   V4  MP4 with a uuid box inside moov  V5 bytes behind the last MP4 box
#   V6  WebM passes  V7 Matroska with an Attachments element
#   S1  a symbolic link (dangling too) is refused unopened, in a directory
#       walk and as an argument
#   S2  sidecar names (.lrv, .srt) refused whatever they hold
#   S3  a file with a NUL byte and no known format refused as binary
#   S4  a text file passes; S5 a media name over text bytes is refused
#   S6  .svg: clean passes, <metadata, inkscape: and xmlns:rdf refused
#   S7  .css with a data:image/ URI refused, with its line number
#   D1  a directory is walked: the clean file is not named, the bad one is
#   O1  -v prints "ok  path", "skip  path (why)" and the count line
#   O2  at most twelve findings per file, then "... and N more findings"
#   J10 APP3 and an APP1 with no known prefix, each holding a coordinate-like
#       string: refused by segment and length, the string never printed
#   P9  tEXt with a keyword that is a coordinate-like string, or exif: plus
#       one: refused, the string never printed; exif:GPSLatitude named whole
#   V8  fragmented MP4: clean passes; a uuid in the first moof, in a traf, a
#       trailing moof holding only a uuid, an mfra holding udta/(c)xyz refused
#   S8  .md with a data:image/ URI refused; a plain .md passes
#   S9  a link given with a trailing slash is refused unopened
#   V9  ilst and keys parsed here, not left to ffprobe: ffmpeg's own MP4, keys
#       MP4 and M4A pass; no hdlr, hdlr late or twice, data_type 13, a data
#       atom past its item, an unlisted item, a location key, a bad key index
#       and a freeform LOCATION refused
#   V10 Matroska Tags parsed: ffmpeg's own Matroska and WebM pass; late Tags,
#       an unmatched TagTrackUID, TagBinary, nested SimpleTags and an unknown
#       size refused
#   E1  no PATH, an unknown option: exit 2 and usage on stderr; -h with any
#       other argument is exit 2, -h alone is help, -- ends the options
#   E2  a video present and no ffprobe on PATH: exit 2 naming ffprobe; a JPEG
#       alone does not need it
#   E3  a PATH that does not exist, and (unless root) an unreadable directory:
#       exit 2
#
# Needs python3, and ffmpeg and ffprobe with libx264, libwebp and libvpx-vp9.
set -uo pipefail

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
TOOL=$SELF/check-media-metadata.py
[ -f "$TOOL" ] || { echo "missing $TOOL" >&2; exit 2; }
for t in python3 ffmpeg ffprobe mktemp; do
  command -v "$t" >/dev/null 2>&1 || { echo "needs $t on PATH" >&2; exit 2; }
done
PY=$(command -v python3)
ENCODERS=$(ffmpeg -hide_banner -encoders 2>/dev/null)
for enc in libx264 libwebp libvpx-vp9; do
  grep -qw "$enc" <<< "$ENCODERS" || { echo "needs ffmpeg with $enc" >&2; exit 2; }
done

W=$(mktemp -d) || { echo "mktemp failed" >&2; exit 2; }
W=$(cd "$W" && pwd -P)
trap 'rm -rf "$W"' EXIT
export HOME="$W/home" TMPDIR="$W/tmp"
mkdir -p "$HOME" "$TMPDIR" "$W/src" "$W/f" || exit 2
F=$W/f

pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok    $1"; }
bad() { failn=$((failn + 1)); echo "FAIL  $1: $2"; }
fatal() { echo "fixture setup failed: $*" >&2; exit 2; }
q() { "$@" >/dev/null 2>&1; }

# ---------------------------------------------------------------- the tool
# run ARGS...: sets OUT (stdout and stderr) and RC.
run() { OUT=$("$PY" -I "$TOOL" "$@" 2>&1); RC=$?; }
# clean NAME FILE: exit 0 and nothing printed.
clean() {
  run "$F/$2"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "$1"; else bad "$1" "exit $RC, output: $OUT"; fi
}
# refuse NAME FILE TEXT [SECRET]: exit 1, a line "FILE: ...TEXT...", SECRET absent.
refuse() {
  run "$F/$2"
  if [ "$RC" -ne 1 ]; then bad "$1" "exit $RC, output: $OUT"; return; fi
  if ! printf '%s\n' "$OUT" | grep -F -- "$F/$2: " | grep -qF -- "$3"; then
    bad "$1" "no line for the file with '$3': $OUT"; return
  fi
  if [ -n "${4:-}" ] && printf '%s' "$OUT" | grep -qF -- "$4"; then
    bad "$1" "the value '$4' is in the output"; return
  fi
  ok "$1"
}

# ---------------------------------------------------------------- fixtures
SRC=(-f lavfi -i testsrc=size=64x48:rate=5:duration=1)
still() { q ffmpeg -y -loglevel error -f lavfi -i testsrc=size=64x48:rate=1:duration=1 -frames:v 1 "$@" || fatal "still $*"; }
still "$W/src/clean.jpg"
still "$W/src/clean.png"
still -c:v libwebp -quality 80 "$W/src/clean.webp"
still "$W/src/clean.gif"
# mp4 OUT [ffmpeg output options]: 1 s, 64x48. The moov box comes last (no
# +faststart), so a box can be added behind it without moving any offset.
mp4() { local out=$1; shift; q ffmpeg -y -loglevel error "${SRC[@]}" -c:v libx264 -pix_fmt yuv420p "$@" "$out" || fatal "mp4 $out"; }
mp4 "$W/src/base.mp4"
mp4 "$F/v1-clean.mp4" -metadata comment="Made with an editor" -metadata title=Demo -metadata creation_time=2026-01-01T00:00:00Z
mp4 "$F/v2-location.mp4" -metadata location=+12.3456-065.4321/
q ffmpeg -y -loglevel error "${SRC[@]}" -c:v libx264 -pix_fmt yuv420p -movflags frag_keyframe+empty_moov "$W/src/frag.mp4" || fatal "fragmented mp4"
mp4 "$F/v3-make.mp4" -movflags use_metadata_tags -metadata make=AcmeCam
q ffmpeg -y -loglevel error "${SRC[@]}" -c:v libvpx-vp9 -b:v 100k "$F/v6-clean.webm" || fatal "webm"
q ffmpeg -y -loglevel error "${SRC[@]}" -c:v libx264 -pix_fmt yuv420p "$W/src/clean.mkv" || fatal "mkv"

mp4 "$F/v9-own.mp4" -metadata title=Demo -metadata comment="Made with an editor"
mp4 "$F/v9-own-keys.mp4" -movflags use_metadata_tags -metadata title=Demo -metadata comment="Made with an editor"
q ffmpeg -y -loglevel error -f lavfi -i sine=duration=1 -c:a aac -metadata title=Demo -metadata comment="Made with an editor" "$F/v9-own.m4a" || fatal "m4a"
q ffmpeg -y -loglevel error "${SRC[@]}" -c:v libx264 -pix_fmt yuv420p -metadata title=Demo -metadata comment="Made with an editor" "$F/v9-own.mkv" || fatal "mkv with tags"
q ffmpeg -y -loglevel error "${SRC[@]}" -c:v libvpx-vp9 -b:v 100k -metadata title=Demo "$F/v9-own.webm" || fatal "webm with tags"

"$PY" -I - "$W/src" "$F" <<'PY' || fatal "byte fixtures"
import os, struct, sys, zlib
src, out = sys.argv[1:3]
rd = lambda n: open(os.path.join(src, n), 'rb').read()
wr = lambda n, b: open(os.path.join(out, n), 'wb').write(b)

# little-endian TIFF: IFD0 -> a GPS IFD with version, latitude and longitude
def tiff_gps():
    ifd0 = struct.pack('<H', 1) + struct.pack('<HHII', 0x8825, 4, 1, 26) + struct.pack('<I', 0)
    n = 5
    data_off = 26 + 2 + n * 12 + 4
    ents = struct.pack('<HHI', 0, 1, 4) + bytes([2, 3, 0, 0])
    ents += struct.pack('<HHI', 1, 2, 2) + b'N\x00\x00\x00'
    ents += struct.pack('<HHII', 2, 5, 3, data_off)
    ents += struct.pack('<HHI', 3, 2, 2) + b'W\x00\x00\x00'
    ents += struct.pack('<HHII', 4, 5, 3, data_off + 24)
    gps = struct.pack('<H', n) + ents + struct.pack('<I', 0)
    return b'II*\x00' + struct.pack('<I', 8) + ifd0 + gps + struct.pack('<6I', 12, 1, 20, 1, 44, 1) + struct.pack('<6I', 65, 1, 25, 1, 56, 1)

XMP = (b'<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="adobe:ns:meta/">'
       b'<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
       b'<rdf:Description xmlns:exif="http://ns.adobe.com/exif/1.0/" exif:GPSLatitude="12,20.7N" exif:GPSLongitude="65,25.9W"/>'
       b'</rdf:RDF></x:xmpmeta><?xpacket end="w"?>')

# ---- JPEG
j = rd('clean.jpg')
assert j[:3] == b'\xff\xd8\xff' and j[-2:] == b'\xff\xd9'
app = lambda n, p: b'\xff' + bytes([0xE0 + n]) + struct.pack('>H', len(p) + 2) + p
com = lambda p: app(0x1E, p)                                 # marker 0xFE
iptc = b'\x1c\x02\x5a\x00\x07Fictown'                        # record 2, dataset 90: City
irb = b'Photoshop 3.0\x00' + b'8BIM' + struct.pack('>H', 0x0404) + b'\x00\x00' + struct.pack('>I', len(iptc)) + iptc
irb += b'\x00' if len(irb) & 1 else b''
# ffmpeg's mjpeg encoder wrote a Lavc COM into clean.jpg itself: take it out, the variants bring their own
j0, o = j[:2], 2
while j[o + 1] != 0xDA:
    n = struct.unpack('>H', j[o + 2:o + 4])[0]
    j0 += b'' if j[o + 1] == 0xFE else j[o:o + 2 + n]
    o += 2 + n
j0 += j[o:]
assert j0 != j
wr('j1-clean.jpg', j)
wr('j2-segments.jpg', j0[:2] + app(0, b'JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00')
   + app(2, b'ICC_PROFILE\x00\x01\x01' + b'\x00' * 40) + app(14, b'Adobe\x00\x64\x80\x00\x00\x00\x00\x00') + j0[2:] + b'\x00\x00\x00\x00')
wr('j3-exif.jpg', j[:2] + app(1, b'Exif\x00\x00' + tiff_gps()) + j[2:])
wr('j4-xmp.jpg', j[:2] + app(1, b'http://ns.adobe.com/xap/1.0/\x00' + XMP) + j[2:])
wr('j5-app13.jpg', j[:2] + app(13, irb) + j[2:])
wr('j6-two-com.jpg', j0[:2] + com(b'Lavc60.31.102\x00') + com(b'Lavc60.31.102\x00') + j0[2:])
wr('j7-com-text.jpg', j0[:2] + com(b'taken at the trailhead') + j0[2:])
wr('j8-trailing.jpg', j + b'GPS 12.3456 -65.4321 alt 1600\n')
wr('j9-truncated.jpg', j[:40])
wr('j10-app3.jpg', j[:2] + app(3, b'GPS 12.3456,-65.4321 Fictown') + j[2:])
wr('j10-app1.jpg', j[:2] + app(1, b'NOTE12.3456,-65.4321') + j[2:])
wr('s5-named.jpg', b'plain text, not a JPEG\n')

# ---- PNG
p = rd('clean.png')
assert p[:8] == b'\x89PNG\r\n\x1a\n'
pc = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
head, rest = p[:33], p[33:]
wr('p1-clean.png', p)
wr('p2-text-ok.png', head + pc(b'tEXt', b'Title\x00A title') + pc(b'tEXt', b'Software\x00ffmpeg') + pc(b'tEXt', b'comment\x00hello') + rest)
wr('p3-itxt-ok.png', head + pc(b'iTXt', b'Title\x00\x00\x00\x00\x00A title') + rest)
wr('p4-exif.png', head + pc(b'eXIf', tiff_gps()) + rest)
wr('p5-ztxt.png', head + pc(b'zTXt', b'Comment\x00\x00' + zlib.compress(b'a note')) + rest)
wr('p6-itxt-compressed.png', head + pc(b'iTXt', b'Comment\x00\x01\x00\x00\x00' + zlib.compress(b'a note')) + rest)
wr('p7-text-gps.png', head + pc(b'tEXt', b'exif:GPSLatitude\x0012.3456') + rest)
wr('p8-trailing.png', p + b'GPS 12.3456 -65.4321\n')
wr('p9-keyword.png', head + pc(b'tEXt', b'12.3456,-65.4321 Fictown\x00v') + rest)
wr('p9-exifval.png', head + pc(b'tEXt', b'exif:12.3456,-65.4321\x00v') + rest)
wr('o2-many.png', head + b''.join(pc(b'tEXt', b'Key%02d\x00v' % i) for i in range(15)) + rest)

# ---- WebP
w = rd('clean.webp')
assert w[:4] == b'RIFF' and w[8:12] == b'WEBP'
vp8 = w[12:]
chunk = lambda cc, d: cc + struct.pack('<I', len(d)) + d + (b'\x00' if len(d) & 1 else b'')
riff = lambda body: b'RIFF' + struct.pack('<I', 4 + len(body)) + b'WEBP' + body
vp8x = lambda flags: chunk(b'VP8X', bytes([flags, 0, 0, 0]) + (63).to_bytes(3, 'little') + (47).to_bytes(3, 'little'))
good = riff(vp8x(0) + vp8)
wr('w1-clean.webp', w)
wr('w1-vp8x.webp', good)
wr('w2-exif.webp', riff(vp8x(0x08) + vp8 + chunk(b'EXIF', tiff_gps())))
wr('w3-xmp.webp', riff(vp8x(0x04) + vp8 + chunk(b'XMP ', XMP)))
wr('w4-riff-size.webp', good[:4] + struct.pack('<I', len(good) - 8 + 100) + good[8:])

# ---- GIF
g = rd('clean.gif')
assert g[:3] == b'GIF' and g[-1] == 0x3B
subs = lambda b: b''.join(bytes([len(b[k:k + 255])]) + b[k:k + 255] for k in range(0, len(b), 255)) + b'\x00'
wr('g1-clean.gif', g)
wr('g2-comment.gif', g[:-1] + b'\x21\xfe' + subs(b'made by a test') + b'\x3b')
wr('g3-xmp.gif', g[:-1] + b'\x21\xff\x0bXMP DataXMP' + subs(XMP) + b'\x3b')

# ---- MP4 boxes (the base has moov last)
m = rd('base.mp4')
i, last = 0, None
while i < len(m):
    size = struct.unpack('>I', m[i:i + 4])[0]
    last = (m[i + 4:i + 8], i, size)
    i += size
assert last[0] == b'moov'
mo, ms = last[1], last[2]
box = lambda t, d: struct.pack('>I', 8 + len(d)) + t + d
moov = m[mo:mo + ms] + box(b'uuid', bytes(range(16)) + b'private bytes')
wr('v4-moov-uuid.mp4', m[:mo] + struct.pack('>I', len(moov)) + moov[4:])
# fragmented MP4: top-level boxes, and the children of the first moof
fm = rd('frag.mp4')
tops, i = [], 0
while i < len(fm):
    size = struct.unpack('>I', fm[i:i + 4])[0]
    tops.append((fm[i + 4:i + 8], fm[i:i + size]))
    i += size
assert [t for t, _ in tops][:3] == [b'ftyp', b'moov', b'moof'] and tops[-1][0] == b'mfra', [t for t, _ in tops]
uuid = box(b'uuid', bytes(range(16)) + b'private bytes')
grow = lambda b, extra: struct.pack('>I', len(b) + len(extra)) + b[4:] + extra
ix = next(k for k, (t, _) in enumerate(tops) if t == b'moof')
def frag(n, boxes):
    wr(n, b''.join(b for _, b in boxes))
wr('v8-clean.mp4', fm)
frag('v8-moof-uuid.mp4', tops[:ix] + [(b'moof', grow(tops[ix][1], uuid))] + tops[ix + 1:])
mh = tops[ix][1]                                  # moof = header, mfhd (16), traf
tf = mh[8 + 16:]
tf2 = grow(tf, uuid)
frag('v8-traf-uuid.mp4', tops[:ix] + [(b'moof', struct.pack('>I', 8 + 16 + len(tf2)) + b'moof' + mh[8:24] + tf2)] + tops[ix + 1:])
frag('v8-trailing-moof.mp4', tops + [(b'moof', box(b'moof', uuid))])
frag('v8-mfra-udta.mp4', tops[:-1] + [(b'mfra', box(b'mfra', box(b'udta', box(b'\xa9xyz', b'+12.3456-065.4321/'))))])
wr('v5-trailing.mp4', m + b'GPS 12.3456 -65.4321 alt 1600')

# ---- Matroska: a Segment with a known size, with an Attachments element added
k = rd('clean.mkv')
si = k.index(b'\x18\x53\x80\x67')
sn = 9 - k[si + 4].bit_length()
ssize = int.from_bytes(k[si + 4:si + 4 + sn], 'big') & ((1 << (7 * sn)) - 1)
assert si + 4 + sn + ssize == len(k), 'the Segment ends at the end of the file'
attach = b'\x19\x41\xa4\x69' + bytes([0x80 | 10]) + b'\xff' * 10
resized = k[:si + 4] + ((1 << (7 * sn)) | (ssize + len(attach))).to_bytes(sn, 'big') + k[si + 4 + sn:]
wr('v7-attachments.mkv', resized + attach)

# ---- MP4 ilst and keys. The base's moov is last, so its udta is replaced without moving an offset.
PLACE = b'Fictown +12.3456-065.4321'                      # a value that must never be printed
kids, i = [], mo + 8
while i < mo + ms:
    n = struct.unpack('>I', m[i:i + 4])[0]
    kids.append((m[i + 4:i + 8], m[i:i + n]))
    i += n
with_udta = lambda payload: m[:mo] + box(b'moov', b''.join(b for t, b in kids if t != b'udta') + box(b'udta', payload))
hdlr_dir = box(b'hdlr', bytes(8) + b'mdir' + b'appl' + bytes(9))
hdlr_mdta = box(b'hdlr', bytes(8) + b'mdta' + bytes(13))
data = lambda d, t=1: box(b'data', struct.pack('>II', t, 0) + d)
item = lambda kind, d, t=1: box(kind, data(d, t))
ilst = lambda *items: box(b'ilst', b''.join(items))
meta = lambda *parts: box(b'meta', bytes(4) + b''.join(parts))
keys = lambda *names: box(b'keys', bytes(4) + struct.pack('>I', len(names)) + b''.join(box(b'mdta', n) for n in names))
free = lambda name, d: box(b'----', box(b'mean', bytes(4) + b'com.apple.iTunes') + box(b'name', bytes(4) + name) + data(d))
def mp4u(n, *parts):
    wr(n, with_udta(meta(*parts)))
mp4u('v9-ok.mp4', hdlr_dir, ilst(item(b'\xa9nam', b'Demo'), item(b'\xa9too', b'Lavf'), item(b'\xa9cmt', b'Hi')))
mp4u('v9-ilst-only.mp4', ilst(item(b'\xa9xyz', PLACE)))
mp4u('v9-ilst-only-title.mp4', ilst(item(b'\xa9nam', PLACE)))
mp4u('v9-ilst-first.mp4', ilst(item(b'\xa9nam', b'Demo')), hdlr_dir)
mp4u('v9-two-hdlr.mp4', hdlr_dir, hdlr_dir, ilst(item(b'\xa9nam', b'Demo')))
mp4u('v9-type13.mp4', hdlr_dir, ilst(item(b'\xa9nam', PLACE, 13)))
lying = struct.pack('>I', 16 + len(PLACE) + 100) + b'data' + struct.pack('>II', 1, 0) + PLACE
mp4u('v9-oversize.mp4', hdlr_dir, ilst(box(b'\xa9nam', lying)))
mp4u('v9-xyz.mp4', hdlr_dir, ilst(item(b'\xa9xyz', PLACE)))
mp4u('v9-zzz.mp4', hdlr_dir, ilst(item(b'\xa9zzz', PLACE)))
mp4u('v9-keys-location.mp4', hdlr_mdta, keys(b'com.apple.quicktime.location.ISO6709'), ilst(item(b'\x00\x00\x00\x01', PLACE)))
mp4u('v9-keys-badindex.mp4', hdlr_mdta, keys(b'title'), ilst(item(b'\x00\x00\x00\x02', PLACE)))
mp4u('v9-keys-nohdlr.mp4', keys(b'title'), ilst(item(b'\x00\x00\x00\x01', b'Demo')))
mp4u('v9-free-location.mp4', hdlr_dir, ilst(free(b'LOCATION', PLACE)))
mp4u('v9-free-comment.mp4', hdlr_dir, ilst(free(b'comment', b'Hi')))

# ---- Matroska Tags, appended behind the Cluster with no SeekHead entry (ffprobe never lists them)
evint = lambda n: b'\x01' + n.to_bytes(7, 'big')
el = lambda ident, d: ident + evint(len(d)) + d
simple = lambda name, extra=b'': el(b'\x67\xc8', el(b'\x45\xa3', name) + el(b'\x44\x87', PLACE) + extra)
tag = lambda *parts, targets=b'': el(b'\x73\x73', el(b'\x63\xc0', targets) + b''.join(parts))
tags = lambda *parts: el(b'\x12\x54\xc3\x67', b''.join(parts))
def mkv_plus(n, extra):
    wr(n, k[:si + 4] + ((1 << (7 * sn)) | (ssize + len(extra))).to_bytes(sn, 'big') + k[si + 4 + sn:] + extra)
mkv_plus('v9-tags-ok.mkv', tags(tag(simple(b'TITLE', simple(b'ENCODER')))))
mkv_plus('v9-tags-location.mkv', tags(tag(simple(b'LOCATION'))))
mkv_plus('v9-tags-unmatched.mkv', tags(tag(simple(b'LOCATION'), targets=el(b'\x63\xc5', (9999).to_bytes(2, 'big')))))
mkv_plus('v9-tags-binary.mkv', tags(tag(simple(b'TITLE', el(b'\x44\x85', b'\x01\x02')))))
mkv_plus('v9-tags-nested.mkv', tags(tag(simple(b'TITLE', simple(b'GPS')))))
mkv_plus('v9-tags-unknown.mkv', tags(b'\x73\x73\x01' + b'\xff' * 7 + simple(b'TITLE')))

# ---- text and binary files
wr('s2-telemetry.srt', b'1\n00:00:00,000 --> 00:00:01,000\nGPS 12.3456 -65.4321\n\n')
wr('s2-clip.lrv', b'plain text in a sidecar name\n')
wr('s3-blob.dat', b'abc\x00def' * 10)
wr('s4-notes.txt', b'plain notes\n')
svg_head = b'<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">\n'
wr('s6-clean.svg', svg_head + b'<path d="M0 0h8v8z"/>\n</svg>\n')
wr('s6-metadata.svg', svg_head + b'<metadata>an author and a path</metadata>\n</svg>\n')
wr('s6-inkscape.svg', svg_head + b'<path inkscape:export-filename="/home/someone/x.png" d="M0 0h8v8z"/>\n</svg>\n')
wr('s6-rdf.svg', b'<svg xmlns="http://www.w3.org/2000/svg" xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n</svg>\n')
wr('s8-data-uri.md', b'# notes\n\n![x](data:image/jpeg;base64,QUJDREVGRw==)\n')
wr('s8-plain.md', b'# notes\n\nplain text with a [link](https://example.com/).\n')
wr('s7-data-uri.css', b'body { margin: 0 }\n\n.logo { background: url(data:image/png;base64,QUJDREVGRw==) }\n')
PY

# ---------------------------------------------------------------- JPEG
clean "J1 JPEG from ffmpeg (Lavc COM) passes" j1-clean.jpg
clean "J2 JFIF, ICC and Adobe segments and NUL padding behind EOI pass" j2-segments.jpg
refuse "J3 APP1 EXIF refused" j3-exif.jpg "APP1 segment: EXIF"
refuse "J4 APP1 XMP refused" j4-xmp.jpg "APP1 segment: XMP"
refuse "J5 APP13 refused" j5-app13.jpg "APP13 segment: Photoshop/IPTC" "Fictown"
refuse "J6 a second COM refused" j6-two-com.jpg "second COM segment"
refuse "J7 a COM that is not the Lavc stamp refused" j7-com-text.jpg "COM segment: free text" "trailhead"
refuse "J8 bytes after EOI refused" j8-trailing.jpg "bytes behind the image data" "12.3456"
refuse "J9 truncated JPEG refused" j9-truncated.jpg "metadata cannot be checked"
refuse "J10a APP3 holding a coordinate-like string: named by length, value not printed" j10-app3.jpg "APP3 segment is not on the allow-list (" "12.3456"
refuse "J10b APP1 with no known prefix: named by length, value not printed" j10-app1.jpg "APP1 segment: unrecognised (" "12.3456"
if ! printf '%s' "$OUT" | grep -qF "NOTE12"; then ok "J10c the APP1 prefix is not printed either"; else bad "J10c" "NOTE12 in: $OUT"; fi

# ---------------------------------------------------------------- PNG
clean "P1 PNG passes" p1-clean.png
clean "P2 tEXt Title, Software and Comment pass" p2-text-ok.png
clean "P3 iTXt Title passes" p3-itxt-ok.png
refuse "P4 eXIf refused" p4-exif.png "eXIf chunk"
refuse "P5 zTXt refused" p5-ztxt.png "zTXt chunk"
refuse "P6 compressed iTXt refused" p6-itxt-compressed.png "iTXt chunk with its compression flag set"
refuse "P7 tEXt with a disallowed keyword refused" p7-text-gps.png "only Title, Software and Comment are allowed" "12.3456"
refuse "P8 bytes after IEND refused" p8-trailing.png "bytes behind the IEND chunk" "12.3456"
refuse "P9a tEXt with a coordinate-like keyword: named by length, value not printed" p9-keyword.png "keyword not on the list (" "12.3456"
if ! printf '%s' "$OUT" | grep -qF "Fictown"; then ok "P9b the keyword's text is not printed"; else bad "P9b" "Fictown in: $OUT"; fi
run "$F/p7-text-gps.png"
if printf '%s' "$OUT" | grep -qF "keyword 'exif:GPSLatitude':"; then ok "P9c a tag name under exif: is named whole"; else bad "P9c" "$OUT"; fi
refuse "P9d exif: followed by something that is not a tag name: the family only" p9-exifval.png "keyword 'exif:*':" "12.3456"

# ---------------------------------------------------------------- WebP
clean "W1a WebP passes" w1-clean.webp
clean "W1b WebP with a VP8X header passes" w1-vp8x.webp
refuse "W2 EXIF chunk refused" w2-exif.webp "EXIF chunk"
refuse "W3 XMP chunk refused" w3-xmp.webp "XMP chunk"
refuse "W4 RIFF size that is not the file's refused" w4-riff-size.webp "bad RIFF size"

# ---------------------------------------------------------------- GIF
clean "G1 GIF passes" g1-clean.gif
refuse "G2 comment extension refused" g2-comment.gif "comment extension"
refuse "G3 XMP application extension refused" g3-xmp.gif "application extension" "12,20.7N"

# ---------------------------------------------------------------- video
clean "V1 MP4 with title, comment and creation_time passes" v1-clean.mp4
refuse "V2 MP4 location tag refused" v2-location.mp4 "tag location (location or device metadata)" "12.3456"
refuse "V3 MP4 make tag refused" v3-make.mp4 "tag make (location or device metadata)" "AcmeCam"
refuse "V4 uuid box inside moov refused" v4-moov-uuid.mp4 "box uuid inside moov"
refuse "V5 bytes behind the last MP4 box refused" v5-trailing.mp4 "not a complete top-level box" "12.3456"
clean "V6 WebM passes" v6-clean.webm
refuse "V7 Matroska Attachments element refused" v7-attachments.mkv "Attachments element"

clean "V8a fragmented MP4 (moof, traf, mfra, as ffmpeg writes them) passes" v8-clean.mp4
refuse "V8b uuid box inside the first moof refused" v8-moof-uuid.mp4 "box uuid inside moof"
refuse "V8c uuid box inside a traf refused" v8-traf-uuid.mp4 "box uuid inside traf"
refuse "V8d trailing moof holding only a uuid refused" v8-trailing-moof.mp4 "box uuid inside moof"
refuse "V8e mfra holding udta/(c)xyz refused" v8-mfra-udta.mp4 "box udta inside mfra is not on the allow-list" "12.3456"

clean "V9a ffmpeg's own MP4 (title, comment, default encoder in ilst) passes" v9-own.mp4
clean "V9b ffmpeg's own MP4 with keys (use_metadata_tags) passes" v9-own-keys.mp4
clean "V9c ffmpeg's own M4A passes" v9-own.m4a
clean "V9d ilst with (c)nam, (c)too, (c)cmt after hdlr passes" v9-ok.mp4
clean "V9e a freeform ---- item named comment passes" v9-free-comment.mp4
refuse "V9f meta with an ilst and no hdlr refused" v9-ilst-only.mp4 "box meta has no hdlr" "Fictown"
refuse "V9g meta with an allowed item and no hdlr refused" v9-ilst-only-title.mp4 "box meta has no hdlr" "Fictown"
refuse "V9h hdlr behind ilst refused" v9-ilst-first.mp4 "hdlr is not its first child"
refuse "V9i two hdlr refused" v9-two-hdlr.mp4 "more than one hdlr"
refuse "V9j an item with data_type 13 refused" v9-type13.mp4 "only data type 1 is allowed" "Fictown"
refuse "V9k a data atom larger than its item refused" v9-oversize.mp4 "runs past its item" "Fictown"
refuse "V9l a (c)xyz item in the normal layout refused, named by its 4CC" v9-xyz.mp4 "ilst item ©xyz is not on the allow-list" "12.3456"
refuse "V9m an unlisted (c)zzz item refused, named by its 4CC" v9-zzz.mp4 "ilst item ©zzz is not on the allow-list" "Fictown"
refuse "V9n a keys entry com.apple.quicktime.location.ISO6709 refused" v9-keys-location.mp4 "keys entry tag com.apple.quicktime.location.ISO6709 (location or device metadata)" "Fictown"
refuse "V9o an ilst item whose key index is not in keys refused" v9-keys-badindex.mp4 "ilst item index 2: its key is missing or not allowed" "Fictown"
refuse "V9p keys and ilst with no hdlr refused" v9-keys-nohdlr.mp4 "box meta has no hdlr"
refuse "V9q a freeform item named LOCATION refused" v9-free-location.mp4 "ilst freeform item tag LOCATION (location or device metadata)" "Fictown"

clean "V10a ffmpeg's own Matroska (title, comment, stream tags) passes" v9-own.mkv
clean "V10b ffmpeg's own WebM with a title passes" v9-own.webm
clean "V10c Tags behind the Cluster with allowed names, nested too, pass" v9-tags-ok.mkv
refuse "V10d late Tags (behind the Cluster, no SeekHead entry) with LOCATION refused" v9-tags-location.mkv "Matroska tag LOCATION (location or device metadata)" "Fictown"
refuse "V10e Tags aimed at a TagTrackUID that matches nothing refused" v9-tags-unmatched.mkv "Matroska tag LOCATION (location or device metadata)" "Fictown"
refuse "V10f TagBinary refused" v9-tags-binary.mkv "TagBinary element inside Matroska Tags"
refuse "V10g a nested SimpleTag GPS refused" v9-tags-nested.mkv "Matroska tag GPS (location or device metadata)" "Fictown"
refuse "V10h an element of unknown size inside Tags refused" v9-tags-unknown.mkv "unknown size inside Matroska Tags"

# ---------------------------------------------------------------- links, names, text
mkdir -p "$W/links"
cp "$F/j1-clean.jpg" "$W/links/real.jpg"
ln -s real.jpg "$W/links/link.jpg"
ln -s "$W/nowhere" "$W/links/dangling.jpg"
run "$W/links"
if [ "$RC" -eq 1 ] && [ "$(printf '%s\n' "$OUT" | grep -c 'symbolic link, never followed')" -eq 2 ] \
   && ! printf '%s\n' "$OUT" | grep -qF "real.jpg"; then
  ok "S1a links in a directory walk: both refused, the real file passes"
else bad "S1a links in a directory walk" "exit $RC: $OUT"; fi
run "$W/links/dangling.jpg"
if [ "$RC" -eq 1 ] && [ "$OUT" = "$W/links/dangling.jpg: symbolic link, never followed, so what it points to is not checked" ]; then
  ok "S1b a dangling link as an argument: refused unopened, not an error"
else bad "S1b a dangling link as an argument" "exit $RC: $OUT"; fi

mkdir -p "$W/linkdir/target"
cp "$F/j3-exif.jpg" "$W/linkdir/target/x.jpg"
ln -s target "$W/linkdir/dl"
for arg in "$W/linkdir/dl" "$W/linkdir/dl/" "$W/linkdir/dl//"; do
  run "$arg"
  if [ "$RC" -eq 1 ] && [ "$OUT" = "$W/linkdir/dl: symbolic link, never followed, so what it points to is not checked" ]; then
    ok "S9 link given as '${arg#"$W/linkdir/"}': refused unopened"
  else bad "S9 link given as '${arg#"$W/linkdir/"}'" "exit $RC: $OUT"; fi
done

refuse "S2a .srt sidecar refused by name" s2-telemetry.srt "sidecar" "12.3456"
refuse "S2b .lrv sidecar refused by name" s2-clip.lrv "sidecar"
refuse "S3 NUL-holding unknown file refused as binary" s3-blob.dat "binary file of an unchecked type"
clean "S4 a text file passes" s4-notes.txt
refuse "S5 a .jpg name over text bytes refused" s5-named.jpg "its name says .jpg"
clean "S6a a clean .svg passes" s6-clean.svg
refuse "S6b .svg with <metadata refused" s6-metadata.svg "<metadata element at line 2" "an author"
refuse "S6c .svg with inkscape: refused" s6-inkscape.svg "inkscape: editor attributes at line 2" "someone"
refuse "S6d .svg with xmlns:rdf refused" s6-rdf.svg "xmlns:rdf (RDF metadata) at line 1"
refuse "S8a .md with a data:image/ URI refused" s8-data-uri.md "inline data: URI of an image, video or audio (not decoded here) at line 3" "QUJDREVG"
clean "S8b a plain .md passes" s8-plain.md
refuse "S7 .css with a data:image/ URI refused with its line" s7-data-uri.css "inline data: URI of an image, video or audio (not decoded here) at line 3" "QUJDREVG"

# ---------------------------------------------------------------- directory, -v, limits
mkdir -p "$W/walk/sub"
cp "$F/p1-clean.png" "$W/walk/a-clean.png"
cp "$F/j3-exif.jpg" "$W/walk/sub/b-exif.jpg"
run "$W/walk"
if [ "$RC" -eq 1 ] && [ "$OUT" = "$W/walk/sub/b-exif.jpg: APP1 segment: EXIF" ]; then
  ok "D1 a directory is walked: only the bad file is named"
else bad "D1 directory walk" "exit $RC: $OUT"; fi

run -v "$F/p1-clean.png" "$F/s4-notes.txt" "$F/j3-exif.jpg"
want="ok  $F/p1-clean.png
skip  $F/s4-notes.txt (not an image or a video)
$F/j3-exif.jpg: APP1 segment: EXIF
checked 2 images and videos: 1 clean, 1 refused; 1 other files skipped"
if [ "$RC" -eq 1 ] && [ "$OUT" = "$want" ]; then ok "O1 -v: ok line, skip line, finding, count line"
else bad "O1 -v output shape" "exit $RC: $OUT"; fi

# fifteen disallowed tEXt chunks: twelve lines, then the count of the rest
run "$F/o2-many.png"
if [ "$RC" -eq 1 ] && [ "$(printf '%s\n' "$OUT" | wc -l)" -eq 13 ] \
   && [ "$(printf '%s\n' "$OUT" | tail -n 1)" = "$F/o2-many.png: ... and 3 more findings" ]; then
  ok "O2 twelve findings per file, then the count of the rest"
else bad "O2 finding limit" "exit $RC, $(printf '%s\n' "$OUT" | wc -l) lines: $(printf '%s\n' "$OUT" | tail -n 1)"; fi

# ---------------------------------------------------------------- exit 2
run
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q '^usage: '; then ok "E1a no PATH: exit 2 and usage"
else bad "E1a no PATH" "exit $RC: $OUT"; fi
run --bogus "$F/p1-clean.png"
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q '^usage: '; then ok "E1b unknown option: exit 2 and usage"
else bad "E1b unknown option" "exit $RC: $OUT"; fi
run
if printf '%s' "$OUT" | grep -qF 'usage: check-media-metadata.py [-v] [--] PATH...'; then ok "E1c the usage line shows [--]"
else bad "E1c usage line" "$OUT"; fi
run "$F/j3-exif.jpg" -h
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q '^usage: '; then ok "E1d PATH then -h: exit 2, not help"
else bad "E1d PATH then -h" "exit $RC: $OUT"; fi
run -h "$F/j3-exif.jpg"
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q '^usage: '; then ok "E1e -h then PATH: exit 2, not help"
else bad "E1e -h then PATH" "exit $RC: $OUT"; fi
run "$F/j3-exif.jpg" --help
if [ "$RC" -eq 2 ]; then ok "E1f PATH then --help: exit 2"
else bad "E1f PATH then --help" "exit $RC: $OUT"; fi
run -h
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'Refuse images and videos'; then ok "E1g -h alone: help, exit 0"
else bad "E1g -h alone" "exit $RC: $OUT"; fi
mkdir "$W/dash"
cp "$F/j3-exif.jpg" "$W/dash/-h"
OUT=$(cd "$W/dash" && "$PY" -I "$TOOL" -- -h 2>&1); RC=$?
if [ "$RC" -eq 1 ] && [ "$OUT" = "-h: APP1 segment: EXIF" ]; then ok "E1h -- ends the options: a file named -h is checked"
else bad "E1h -- -h" "exit $RC: $OUT"; fi
OUT=$(cd "$W/dash" && "$PY" -I "$TOOL" -v -- -h 2>&1); RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF -- '-h: APP1 segment: EXIF'; then ok "E1i -v then -- then -h: the file is checked"
else bad "E1i -v -- -h" "exit $RC: $OUT"; fi

# An option-shaped name that is also a file: a glob must not turn it into a flag.
mkdir "$W/optv"
cp "$F/j3-exif.jpg" "$W/optv/-v"
cp "$F/s4-notes.txt" "$W/optv/ok.txt"
OUT=$(cd "$W/optv" && "$PY" -I "$TOOL" * 2>&1); RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qF 'both an option and a file' && printf '%s' "$OUT" | grep -qF -- '--'; then ok "E1j a file named -v under a glob: exit 2, not the flag"
else bad "E1j * with a file named -v" "exit $RC: $OUT"; fi
OUT=$(cd "$W/optv" && "$PY" -I "$TOOL" -- * 2>&1); RC=$?
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF -- '-v: APP1 segment: EXIF'; then ok "E1k -- * with a file named -v: the file is checked"
else bad "E1k -- * with -v" "exit $RC: $OUT"; fi
mkdir "$W/opth"
cp "$F/j3-exif.jpg" "$W/opth/-h"
cp "$F/s4-notes.txt" "$W/opth/ok.txt"
OUT=$(cd "$W/opth" && "$PY" -I "$TOOL" * 2>&1); RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qF 'both an option and a file'; then ok "E1l a file named -h under a glob: exit 2"
else bad "E1l * with a file named -h" "exit $RC: $OUT"; fi
OUT=$(cd "$F" && "$PY" -I "$TOOL" -v j1-clean.jpg 2>&1); RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'checked 1 '; then ok "E1m -v PATH with no file named -v: verbose, as before"
else bad "E1m -v PATH" "exit $RC: $OUT"; fi

mkdir "$W/nobin"
OUT=$(PATH="$W/nobin" "$PY" -I "$TOOL" "$F/v1-clean.mp4" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'ffprobe is not on PATH'; then ok "E2a a video and no ffprobe: exit 2 naming ffprobe"
else bad "E2a no ffprobe" "exit $RC: $OUT"; fi
OUT=$(PATH="$W/nobin" "$PY" -I "$TOOL" "$F/j1-clean.jpg" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "E2b a JPEG alone does not need ffprobe"
else bad "E2b JPEG without ffprobe" "exit $RC: $OUT"; fi

run "$W/does-not-exist"
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qF "check-media-metadata.py: $W/does-not-exist: "; then ok "E3a a PATH that does not exist: exit 2"
else bad "E3a missing PATH" "exit $RC: $OUT"; fi
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$W/locked/inner"
  cp "$F/p1-clean.png" "$W/locked/inner/x.png"
  chmod 000 "$W/locked/inner"
  run "$W/locked"
  chmod 755 "$W/locked/inner"
  if [ "$RC" -eq 2 ]; then ok "E3b an unreadable directory: exit 2"
  else bad "E3b unreadable directory" "exit $RC: $OUT"; fi
else
  echo "skip  E3b an unreadable directory (running as root)"
fi

echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
