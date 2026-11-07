#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Joe Fernandez
"""Refuse images and videos that carry location or device metadata.

    python3 -I check-media-metadata.py [-v] PATH...

Each PATH is a file or a directory, walked. A symbolic link, or anything else
that is not a plain file, is a finding and is never opened or followed. Every
plain file is opened and told apart by its first bytes, whatever its name;
the name only decides two things (see "Sidecars" and "Cannot be read").

One "path: reason" line per finding on stdout, the tag or segment named and
never its value (a value may be the coordinates), twelve findings at most per
file, then one line with the count of the rest. With -v also "ok  path" for each clean file, "skip  path (why)" for each
file that is not an image or a video, and a count at the end.

Exit 0: nothing refused. Exit 1: at least one finding. Exit 2: usage, an
unreadable PATH, or ffprobe missing while a video is present.

An allow-list for every format: a file is clean only if everything in it is on
its format's list, so what is unknown is refused too, harmful or not.

  JPEG   markers: the frame headers, the tables (DQT, DHT, DAC, DRI, DNL, EXP),
         SOS; APP0 JFIF, APP2 ICC_PROFILE, APP14 Adobe. Refused: APP1
         (EXIF, XMP, other), APP13 (Photoshop, IPTC), APP11 (JUMBF, C2PA), every
         other APPn (an APP2 MPF holds a second image), COM (free text) and
         every other marker. A COM passes only if its whole payload is the
         encoder stamp of ffmpeg, Lavc then digits and dots (Lavc60.31.102),
         with at most one trailing NUL, and it is the only COM: a stamp with
         anything appended, an empty COM or a second COM is refused.
  PNG    chunks: IHDR PLTE IDAT IEND tRNS gAMA cHRM sRGB iCCP sBIT bKGD hIST
         pHYs sPLT tIME acTL fcTL fdAT cICP mDCV cLLI. Text chunks (tEXt, iTXt)
         only with the keyword Title, Software or Comment, in any case.
         Refused: eXIf, caBX (C2PA), XMP, any other keyword (ImageMagick turns
         EXIF into tEXt exif:GPSLatitude and the like), any zTXt and any iTXt
         with its compression flag set (compressed text is not decompressed
         here, so what it holds cannot be seen), any other chunk.
  WebP   chunks: VP8, VP8L, VP8X, ALPH, ANIM, ANMF (and inside it ALPH, VP8,
         VP8L), ICCP. Refused: EXIF, XMP, C2PA, any other; a chunk that runs
         past the declared RIFF size; a RIFF size that is not the file's.
  GIF    blocks: header, screen and colour tables, image descriptors, graphic
         control, the NETSCAPE and ANIMEXTS application extensions. Refused:
         comment and plain text extensions (free text), any other application
         extension (XMP travels in one) and any other extension.
  video  (MP4, MOV, 3GP, M4A... "ftyp" at byte 4; Matroska and WebM, EBML) read
         with ffprobe -show_format -show_streams -show_chapters -of json, and
         for the MP4 family -export_xmp 1 -export_all 1 (without them ffprobe
         hides an XMP packet and unknown udta atoms such as GPS). A tag, on the
         container, a stream or a chapter, is clean only if it is major_brand,
         minor_version, compatible_brands, encoder, handler_name, language,
         vendor_id, creation_time, title or comment; the Matroska muxers also
         write duration, bps, number_of_frames, number_of_bytes and
         _statistics_writing_app, _statistics_writing_date_utc and
         _statistics_tags, which are let through. Keys are matched without case.
         A tag named xmp, or one with a part named location, make, model,
         manufacturer, imei or beginning serial, gps, latitude or longitude, is
         named as such. Also refused: a stream that is not video or audio (a
         GoPro, DJI or Apple telemetry track, a subtitle, an attachment), an
         attached picture (cover art can carry EXIF; ffmpeg -map 0:V leaves it
         out), and an HEIF or AVIF still image (brands heic heix mif1 avif and
         the like: its EXIF items are invisible to ffprobe).
         For the MP4 family the boxes are walked, to every depth that matters,
         because ffprobe shows only the tags it knows. Refused: bytes behind
         the last top-level box, a box that runs past its container or the end
         of the file, a top-level box other than ftyp styp moov mdat moof mfra
         sidx ssix free skip wide pdin, a uuid box at any depth (XMP and private
         data travel in it), and inside the containers moov trak mdia minf stbl
         dinf edts udta mvex moof traf mfra and meta (a full box: its 4 version and flag bytes
         are skipped) any child not on that container's list (see BMFF_CHILDREN;
         meta may hold only hdlr, ilst and keys, never xml, bxml, iinf, iloc or
         idat). ilst and keys are left to ffprobe; other boxes are leaves and are
         not parsed past their header. A free, skip or wide box at any depth
         whose payload is not all zero bytes.
         For Matroska and WebM the EBML header and the Segment are read: refused
         are a Segment of unknown size (it cannot be checked), any bytes behind
         the Segment, and an Attachments element (ID 0x1941A469) among the
         Segment's top-level children, which are walked by ID and size only.
  tail   bytes behind the end of a JPEG, PNG, WebP or GIF are refused unless
         they are only NUL or white space, and an EXIF, XMP, JUMBF or Photoshop
         signature among them is named.

Sidecars. A file named .lrv, .lrf, .thm, .insv, .insp or .srt (GoPro, DJI and
Insta360 proxies, thumbnails and telemetry subtitles) is refused whatever it
holds: GPS and EXIF travel with them.

Cannot be read. Unchecked formats are refused, named: TIFF, JPEG 2000, JPEG XL,
Ogg, FLAC, MP3 with an ID3 tag, FLV, ASF, MPEG program and transport streams,
RIFF (AVI, WAVE). So is a file whose name says image or video (.jpg .png .webp
.gif .mp4 .mov .webm .mkv .avi .heic .avif .tiff and the like) but whose first
bytes are none of the formats above, or that is truncated or malformed.

Not media, and so not decoded. A file that is none of the formats above and is not
refused by name is read for two things only. If it holds a NUL byte anywhere it is
refused as a binary file of an unchecked type (fonts, PDFs, .ico, .bmp, .psd, .mp3
without a tag and the like: publish what can be checked, or convert it). If it is
text, nothing more is read unless its name is .svg .css .html .htm .xml .txt .json
.js .webmanifest .md or .markdown: those are refused for a data:image/, data:video/ or
data:audio/ URI (an inline picture is not decoded here), and an .svg also for
<metadata, sodipodi:, inkscape: and xmlns:rdf (editor and RDF metadata). The
construct and its line number are printed, never the text. Clean text is passed
and listed by -v as skipped.

What this does not check: the contents of an inline picture or of an ilst or keys
box (ffprobe's tags are checked, not the pictures behind them); the values of the
free-text tags that are allowed (title, comment, handler_name, vendor_id, PNG
Title, Software and Comment): a place name written there passes; the inside of an
ICC profile, or of an APP0, APP2 or APP14 segment past its prefix; a PDF, font or
other binary (refused unread); text in any file but the eleven extensions above;
data: URIs other than image, video and audio; Matroska elements inside the
Segment other than Attachments (ffprobe reads the tags); and anything behind a
base64 or other encoding in text.
"""
import json
import os
import re
import shutil
import stat
import subprocess
import sys

STILL_EXT = {'.jpg', '.jpeg', '.jpe', '.jfif', '.png', '.webp', '.gif'}
VIDEO_EXT = {'.mp4', '.m4v', '.m4a', '.mov', '.qt', '.3gp', '.3g2', '.webm', '.mkv', '.avi',
             '.mpg', '.mpeg', '.mts', '.m2ts', '.ogv', '.flv', '.wmv'}
UNCHECKED_EXT = {'.avif', '.heic', '.heif', '.tif', '.tiff', '.jxl', '.jp2', '.j2k', '.dng'}
TEXT_EXT = {'.svg', '.css', '.html', '.htm', '.xml', '.txt', '.json', '.js', '.webmanifest',
            '.md', '.markdown'}
SIDECAR_EXT = {'.lrv', '.lrf', '.thm', '.insv', '.insp', '.srt'}

MAGIC_PNG = b'\x89PNG\r\n\x1a\n'
OTHER_MEDIA = (
    (b'II*\x00', 'TIFF'), (b'MM\x00*', 'TIFF'),
    (b'\x00\x00\x00\x0cjP  ', 'JPEG 2000'), (b'\xff\x4f\xff\x51', 'JPEG 2000'),
    (b'\x00\x00\x00\x0cJXL ', 'JPEG XL'),
    (b'OggS', 'Ogg'), (b'fLaC', 'FLAC'), (b'ID3', 'MP3 with an ID3 tag'),
    (b'FLV\x01', 'FLV'), (b'\x30\x26\xb2\x75\x8e\x66\xcf\x11', 'ASF/WMV'),
    (b'\x00\x00\x01\xba', 'an MPEG program stream'), (b'\x00\x00\x01\xb3', 'MPEG video'),
    (b'.RMF', 'RealMedia'),
)

MAX_STILL = 256 << 20          # a still bigger than this is not read into memory
MAX_LINES = 12                 # findings printed per file

XMP_SIGNATURES = (b'http://ns.adobe.com/xap/1.0/', b'http://ns.adobe.com/xmp/extension/', b'<x:xmpmeta')

# --- tags (video) ---------------------------------------------------------
TAG_ALLOW = {'major_brand', 'minor_version', 'compatible_brands', 'encoder', 'handler_name',
             'language', 'vendor_id', 'creation_time', 'title', 'comment',
             # written by the Matroska muxers (ffmpeg, mkvmerge): sizes, times, the app's name
             'duration', 'bps', 'number_of_frames', 'number_of_bytes',
             '_statistics_writing_app', '_statistics_writing_date_utc', '_statistics_tags'}
TAG_EXACT = {'make', 'model', 'manufacturer', 'imei', '©xyz', '©mak', '©mod'}
TAG_PREFIX = ('location', 'serial', 'gps', 'latitude', 'longitude')

BMFF_TOP_OK = {b'ftyp', b'styp', b'moov', b'mdat', b'moof', b'mfra', b'sidx', b'ssix',
               b'free', b'skip', b'wide', b'pdin'}
# Children allowed inside each container box (ISO/IEC 14496-12; the 3GPP, iTunes
# and QuickTime extras are deliberately absent). free, skip and wide are allowed
# in every container except meta, with an all-zero payload (see bmff_walk).
BMFF_CHILDREN = {
    b'moov': {b'mvhd', b'trak', b'mvex', b'udta', b'meta', b'iods', b'pssh'},
    b'trak': {b'tkhd', b'tref', b'trgr', b'edts', b'mdia', b'meta', b'udta'},
    b'mdia': {b'mdhd', b'hdlr', b'minf', b'elng'},
    b'minf': {b'vmhd', b'smhd', b'hmhd', b'nmhd', b'sthd', b'dinf', b'stbl'},
    b'stbl': {b'stsd', b'stts', b'ctts', b'cslg', b'stsc', b'stsz', b'stz2', b'stco', b'co64',
              b'stss', b'stsh', b'padb', b'stdp', b'sdtp', b'sbgp', b'sgpd', b'subs',
              b'saiz', b'saio', b'senc'},
    b'dinf': {b'dref'},
    b'edts': {b'elst'},
    b'udta': {b'cprt', b'tsel', b'kind', b'strk', b'meta'},
    b'mvex': {b'mehd', b'trex', b'leva'},
    # fragmented MP4: ffmpeg writes mfhd, traf (tfhd tfdt trun) and mfra (tfra mfro)
    b'moof': {b'mfhd', b'traf'},
    b'traf': {b'tfhd', b'tfdt', b'trun', b'sbgp', b'sgpd', b'subs', b'saiz', b'saio', b'senc'},
    b'mfra': {b'tfra', b'mfro'},
    b'meta': {b'hdlr', b'ilst', b'keys'},
}
BMFF_PADDING = {b'free', b'skip', b'wide'}
MAX_BOX_FINDINGS = 100          # a walk stops after this many
IMAGE_BRANDS = {b'heic', b'heix', b'heim', b'heis', b'hevc', b'hevx', b'hevm', b'hevs',
                b'mif1', b'msf1', b'avif', b'avis', b'avci', b'avcs'}


def shown(b, n=40):
    return b[:n].decode('latin-1').replace('\x00', '').replace('\n', ' ')


def tail_findings(tail, where):
    """Bytes behind the end of the image: only padding is allowed."""
    if not tail.strip(b'\x00 \t\r\n'):
        return []
    out = ['%d bytes behind %s: appended data cannot be checked' % (len(tail), where)]
    if b'Exif\x00\x00' in tail:
        out.append('EXIF signature behind %s' % where)
    if any(s in tail for s in XMP_SIGNATURES) or b'<?xpacket' in tail:
        out.append('XMP signature behind %s' % where)
    if b'jumb' in tail and b'c2pa' in tail:
        out.append('C2PA (JUMBF) data behind %s' % where)
    if b'Photoshop 3.0' in tail:
        out.append('Photoshop (IPTC) data behind %s' % where)
    return out


# --- JPEG ----------------------------------------------------------------
JPEG_PLAIN = {0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE,
              0xCF, 0xDA, 0xDB, 0xDC, 0xDD, 0xDF}           # frame headers, tables, SOS


JPEG_COM_OK = re.compile(rb'Lavc[0-9]+(\.[0-9]+)*\x00?')     # the encoder stamp of ffmpeg, nothing else


def jpeg_segment(m, seg, seen_com=False):
    """None if the segment is on the allow-list, else why not."""
    if m in JPEG_PLAIN:
        return None
    if m == 0xFE:
        if seen_com:
            return 'second COM segment: free text cannot be checked'
        if JPEG_COM_OK.fullmatch(seg):
            return None
        return 'COM segment: free text cannot be checked (only the Lavc version stamp of ffmpeg passes)'
    if m == 0xE0:
        return None if seg[:5] == b'JFIF\x00' else 'APP0 segment is not JFIF (%d bytes)' % len(seg)
    if m == 0xE2:
        return None if seg[:12] == b'ICC_PROFILE\x00' else 'APP2 segment is not an ICC profile (%d bytes)' % len(seg)
    if m == 0xEE:
        return None if seg[:5] == b'Adobe' else 'APP14 segment is not Adobe (%d bytes)' % len(seg)
    if m == 0xE1:
        if seg[:4].lower() == b'exif':
            return 'APP1 segment: EXIF'
        if any(s in seg[:64] for s in XMP_SIGNATURES) or seg[:5] == b'<?xpa':
            return 'APP1 segment: XMP'
        return 'APP1 segment: unrecognised (%d bytes)' % len(seg)
    if m == 0xED:
        if seg[:13] == b'Photoshop 3.0':
            return 'APP13 segment: Photoshop/IPTC'
        return 'APP13 segment: unrecognised (%d bytes)' % len(seg)
    if m == 0xEB:
        return 'APP11 segment: JUMBF/C2PA' if b'jumb' in seg[:64] else 'APP11 segment: unrecognised (%d bytes)' % len(seg)
    if 0xE0 <= m <= 0xEF:
        return 'APP%d segment is not on the allow-list (%d bytes)' % (m - 0xE0, len(seg))
    return 'marker 0x%02X is not on the allow-list' % m


def next_scan_marker(data, i):
    """The offset of the next real marker in entropy-coded data, or None."""
    n = len(data)
    while True:
        j = data.find(b'\xff', i)
        if j == -1 or j + 1 >= n:
            return None
        b = data[j + 1]
        if b == 0x00 or 0xD0 <= b <= 0xD7:       # a stuffed byte, a restart marker
            i = j + 2
        elif b == 0xFF:                          # fill
            i = j + 1
        else:
            return j


def jpeg_findings(data):
    out = []
    n = len(data)
    i = 2                                        # past SOI
    in_scan = False
    ended = False
    com = False                                  # a COM segment has been seen
    while True:
        if in_scan:
            i = next_scan_marker(data, i)
            if i is None:
                break
            in_scan = False
        if i + 2 > n:
            break
        if data[i] != 0xFF:
            return out + ['malformed JPEG (no marker at byte %d), so its metadata cannot be checked' % i]
        m = data[i + 1]
        if m == 0xFF:
            i += 1
            continue
        if m == 0xD9:
            i += 2
            ended = True
            break
        if m in (0x00, 0xD8):
            return out + ['malformed JPEG (unexpected marker 0x%02X at byte %d)' % (m, i)]
        if m == 0x01 or 0xD0 <= m <= 0xD7:
            i += 2
            continue
        length = int.from_bytes(data[i + 2:i + 4], 'big')
        if i + 4 > n or length < 2 or i + 2 + length > n:
            return out + ['malformed JPEG (bad segment length at byte %d), so its metadata cannot be checked' % i]
        why = jpeg_segment(m, data[i + 4:i + 2 + length], com)
        com = com or m == 0xFE
        if why:
            out.append(why)
        i += 2 + length
        if m == 0xDA:
            in_scan = True
    if not ended:
        return out + ['truncated JPEG: no end-of-image marker, so its metadata cannot be checked']
    return out + tail_findings(data[i:], 'the image data')


# --- PNG -----------------------------------------------------------------
PNG_PLAIN = {b'IHDR', b'PLTE', b'IDAT', b'IEND', b'tRNS', b'gAMA', b'cHRM', b'sRGB', b'iCCP',
             b'sBIT', b'bKGD', b'hIST', b'pHYs', b'sPLT', b'tIME', b'acTL', b'fcTL', b'fdAT',
             b'cICP', b'mDCV', b'cLLI'}
PNG_TEXT = {b'tEXt', b'zTXt', b'iTXt'}
PNG_KEYWORDS = {b'title', b'software', b'comment'}
# Keywords that may be printed by name, because they are refused by name: the
# PNG specification's own, and the families ImageMagick and exiftool write. Any
# other keyword is printed as a length: its text may be a value.
PNG_REFUSED_NAMES = {b'author', b'description', b'copyright', b'creation time', b'source',
                     b'warning', b'disclaimer'}
PNG_REFUSED_FAMILIES = (b'exif:', b'tiff:', b'xmp', b'gps', b'date:')
PNG_TAG_NAME = re.compile(rb'[A-Za-z][A-Za-z]*[0-9]?[A-Za-z]*[0-9]?[A-Za-z]*')    # GPSLatitude, GPSVersionID, ISOSpeedRatings


def png_keyword(keyword):
    """How a refused keyword is named in a message: by name only if it is a known one."""
    low = keyword.lower()
    if low in PNG_REFUSED_NAMES:
        return repr(low.decode('latin-1'))
    for fam in PNG_REFUSED_FAMILIES:
        if low.startswith(fam):
            # exif:GPSLatitude is a tag name and is printed whole, which is how a
            # reader learns what to remove; a rest that is not shaped like one
            # (punctuation, digits in a run) may be a value, and is not.
            if fam in (b'exif:', b'tiff:') and len(keyword) <= 48 and PNG_TAG_NAME.fullmatch(keyword[len(fam):]):
                return repr(keyword.decode('latin-1'))
            return repr(fam.decode('latin-1') + '*')
    return 'not on the list (%d bytes)' % len(keyword)


def png_findings(data):
    out = []
    n = len(data)
    i = 8
    ended = False
    while i + 12 <= n:
        length = int.from_bytes(data[i:i + 4], 'big')
        kind = data[i + 4:i + 8]
        if i + 12 + length > n:
            return out + ['truncated PNG chunk %s, so its metadata cannot be checked' % shown(kind)]
        name = kind.decode('latin-1')
        if kind in PNG_PLAIN:
            pass
        elif kind in PNG_TEXT:
            body = data[i + 8:i + 8 + length]
            keyword = body.split(b'\x00', 1)[0]
            low = keyword.lower()
            if kind == b'zTXt':
                out.append('zTXt chunk (compressed text, not decompressed here, so what it holds cannot be checked)')
            elif kind == b'iTXt' and body[len(keyword) + 1:len(keyword) + 2] == b'\x01':
                out.append('iTXt chunk with its compression flag set (compressed text cannot be checked)')
            if low == b'xml:com.adobe.xmp' or any(s in body for s in XMP_SIGNATURES):
                out.append('%s chunk holding XMP' % name)
            elif low.startswith(b'raw profile type'):
                out.append('%s chunk holding an embedded profile (keyword raw profile type *)' % name)
            elif low not in PNG_KEYWORDS:
                out.append('%s chunk with keyword %s: only Title, Software and Comment are allowed'
                           % (name, png_keyword(keyword)))
            elif b'Exif\x00\x00' in body:
                out.append('%s chunk %r holding EXIF' % (name, shown(keyword)))
        elif kind == b'eXIf':
            out.append('eXIf chunk (EXIF)')
        elif kind == b'caBX':
            out.append('caBX chunk (C2PA)')
        else:
            out.append('chunk %s is not on the allow-list' % shown(kind))
        i += 12 + length
        if kind == b'IEND':
            ended = True
            break
    if not ended:
        return out + ['PNG without an IEND chunk, so its metadata cannot be checked']
    return out + tail_findings(data[i:], 'the IEND chunk')


# --- WebP ----------------------------------------------------------------
WEBP_PLAIN = {b'VP8 ', b'VP8L', b'VP8X', b'ALPH', b'ANIM', b'ANMF', b'ICCP'}
WEBP_FRAME = {b'ALPH', b'VP8 ', b'VP8L'}


def webp_chunks(data, i, end, allowed, out, inside):
    """Walk the chunks in data[i:end]; return the offset the walk reached."""
    while i + 8 <= end:
        kind = data[i:i + 4]
        length = int.from_bytes(data[i + 4:i + 8], 'little')
        stop = i + 8 + length
        if stop > end:
            out.append('chunk %s runs past the declared %s' % (shown(kind), inside))
            return end
        if kind not in allowed:
            label = {b'EXIF': 'EXIF chunk', b'XMP ': 'XMP chunk', b'C2PA': 'C2PA chunk'}.get(kind.upper())
            out.append(label or 'chunk %s is not on the allow-list' % shown(kind))
        elif kind == b'ANMF':
            webp_chunks(data, i + 8 + 16, stop, WEBP_FRAME, out, 'ANMF frame')
        i = min(stop + (length & 1), end)         # a chunk is padded to an even size
    return i


def webp_findings(data):
    out = []
    n = len(data)
    declared = 8 + int.from_bytes(data[4:8], 'little')
    if declared > n:
        out.append('bad RIFF size: it says %d bytes and the file has %d' % (declared, n))
    elif declared < n:
        out.append('bad RIFF size: it says %d bytes and the file has %d' % (declared, n))
        out += tail_findings(data[declared:], 'the declared RIFF size')
    end = min(declared, n)
    reached = webp_chunks(data, 12, end, WEBP_PLAIN, out, 'RIFF size')
    if reached < end:
        out.append('%d bytes inside the RIFF are not a chunk' % (end - reached))
    return out


# --- GIF -----------------------------------------------------------------
def gif_findings(data):
    out = []
    n = len(data)
    if n < 13 or data[:6] not in (b'GIF87a', b'GIF89a'):
        return ['not a valid GIF header, so its metadata cannot be checked']
    i = 13
    if data[10] & 0x80:
        i += 3 * (2 << (data[10] & 7))

    def sub_blocks(j):                            # past a chain of data sub-blocks, or None
        while j < n:
            size = data[j]
            j += 1
            if size == 0:
                return j
            j += size
        return None

    ended = False
    while i is not None and i < n:
        b = data[i]
        if b == 0x3B:
            i += 1
            ended = True
            break
        if b == 0x2C:                             # image descriptor
            if i + 10 > n:
                break
            packed = data[i + 9]
            i += 10
            if packed & 0x80:
                i += 3 * (2 << (packed & 7))
            i = sub_blocks(i + 1)                 # one byte of LZW code size, then the data
        elif b == 0x21 and i + 2 <= n:            # extension
            label = data[i + 1]
            i += 2
            if label == 0xFF:
                app = data[i + 1:i + 12] if i < n else b''
                if app[:8] not in (b'NETSCAPE', b'ANIMEXTS'):
                    out.append('application extension %r%s is not on the allow-list'
                               % (shown(app, 11), ' (XMP)' if app[:3] == b'XMP' else ''))
            elif label == 0xFE:
                out.append('comment extension: free text cannot be checked')
            elif label == 0x01:
                out.append('plain text extension: free text cannot be checked')
            elif label != 0xF9:
                out.append('extension 0x%02X is not on the allow-list' % label)
            i = sub_blocks(i)
        else:
            return out + ['malformed GIF (unexpected byte 0x%02X at byte %d), so its metadata cannot be checked' % (b, i)]
    if not ended:
        return out + ['truncated GIF: no trailer, so its metadata cannot be checked']
    return out + tail_findings(data[i:], 'the GIF trailer')


# --- video: ISO BMFF (MP4, MOV, 3GP, M4A) and Matroska (WebM) -----------------
def bad_tag(key):
    for part in re.split(r'[^0-9a-z©]+', key.lower()):
        if part in TAG_EXACT or part.startswith(TAG_PREFIX):
            return True
    return False


def tag_findings(where, tags):
    out = []
    for key in sorted(tags or {}):
        low = key.lower().strip()
        if low in TAG_ALLOW:
            continue
        if low == 'xmp':
            out.append('%s tag xmp: an XMP packet, where location and device fields travel' % where)
        elif bad_tag(low):
            out.append('%s tag %s (location or device metadata)' % (where, key.strip()))
        else:
            out.append('%s tag %s is not on the allow-list' % (where, key.strip()))
    return out


def all_zero(f, start, length):
    """True if length bytes of f from start are all NUL (read in chunks)."""
    f.seek(start)
    while length > 0:
        chunk = f.read(min(length, 1 << 20))
        if not chunk:
            return False
        if chunk.strip(b'\x00'):
            return False
        length -= len(chunk)
    return True


def bmff_walk(f, pos, end, parent, out, brands):
    """Walk the boxes in f[pos:end]; parent is the container's type, None at the top level."""
    top = parent is None
    allowed = BMFF_TOP_OK if top else BMFF_CHILDREN[parent]
    where = 'the top level' if top else parent.decode('latin-1')
    while pos < end:
        if len(out) >= MAX_BOX_FINDINGS:
            return
        f.seek(pos)
        hdr = f.read(16)
        ok = len(hdr) >= 8 and end - pos >= 8
        if ok:
            bsize = int.from_bytes(hdr[:4], 'big')
            kind = hdr[4:8]
            hlen = 8
            if bsize == 1:                        # a 64-bit size follows
                ok = len(hdr) == 16
                bsize = int.from_bytes(hdr[8:16], 'big')
                hlen = 16
            elif bsize == 0:                      # the box runs to the end of its container
                bsize = end - pos
            ok = ok and hlen <= bsize and pos + bsize <= end
        if not ok:
            if not top and end - pos < 8 and all_zero(f, pos, end - pos):
                return                            # the zero terminator QuickTime writes
            if top:
                out.append('%d bytes from byte %d on are not a complete top-level box: appended data, or a truncated file'
                           % (end - pos, pos))
            else:
                out.append('%d bytes from byte %d on, inside %s, are not a complete box: a box that runs past its container, or appended data'
                           % (end - pos, pos, where))
            return
        name = shown(kind)
        padding = kind in BMFF_PADDING and parent != b'meta'
        if kind not in allowed and not padding:
            if top:
                out.append('top-level box %s is not on the allow-list (uuid and meta can hold XMP and items)' % name)
            elif kind == b'uuid':
                out.append('box uuid inside %s (XMP and private data travel in uuid boxes)' % where)
            else:
                out.append('box %s inside %s is not on the allow-list' % (name, where))
        elif padding:
            if not all_zero(f, pos + hlen, bsize - hlen):
                out.append('%s box %s holds non-zero bytes (padding can hide data)' % (name, 'at the top level' if top else 'inside ' + where))
        elif kind in BMFF_CHILDREN:
            start = pos + hlen
            if kind == b'meta':                   # a full box: version and flags first
                start += 4
            if start > pos + bsize:
                out.append('box %s inside %s is too short for its header' % (name, where))
            else:
                bmff_walk(f, start, pos + bsize, kind, out, brands)
        elif top and kind == b'ftyp' and not brands:
            f.seek(pos + hlen)
            payload = f.read(min(bsize - hlen, 4096))
            brands.extend([payload[:4]] + [payload[k:k + 4] for k in range(8, len(payload) - 3, 4)])
        pos += bsize


def bmff_boxes(path):
    """Walk the boxes. Returns (findings, brands)."""
    out = []
    brands = []
    with open(path, 'rb') as f:
        bmff_walk(f, 0, os.path.getsize(path), None, out, brands)
    return out, brands


# Matroska and WebM: the EBML header, then the Segment, walked by element ID and size.
EBML_MAGIC = 0x1A45DFA3
EBML_SEGMENT = 0x18538067
EBML_ATTACHMENTS = 0x1941A469


def ebml_vint(f, is_id):
    """(value, length) of the variable-length integer at f's position, or None.
    An ID keeps its marker bit; a size loses it, and an all-ones size (unknown) is -1."""
    first = f.read(1)
    if not first or first[0] == 0:
        return None
    n = 9 - first[0].bit_length()
    rest = f.read(n - 1)
    if len(rest) != n - 1 or (is_id and n > 4):
        return None
    raw = int.from_bytes(first + rest, 'big')
    if is_id:
        return raw, n
    val = raw & ((1 << (7 * n)) - 1)
    return (-1 if val == (1 << (7 * n)) - 1 else val), n


def ebml_element(f, pos):
    """(id, size, header length) of the element at pos; size -1 is unknown; None if malformed."""
    f.seek(pos)
    ident = ebml_vint(f, True)
    size = ebml_vint(f, False) if ident else None
    return (ident[0], size[0], ident[1] + size[1]) if ident and size else None


def ebml_findings(path):
    out = []
    n = os.path.getsize(path)
    with open(path, 'rb') as f:
        head = ebml_element(f, 0)
        if not head or head[0] != EBML_MAGIC or head[1] < 0 or head[2] + head[1] > n:
            return ['malformed EBML header, so its structure cannot be checked']
        pos = head[2] + head[1]
        seg = ebml_element(f, pos)
        if not seg or seg[0] != EBML_SEGMENT:
            return ['no Segment element after the EBML header, so its structure cannot be checked']
        if seg[1] < 0:
            return ['Matroska Segment of unknown size: its elements cannot be checked']
        start = pos + seg[2]
        end = start + seg[1]
        if end > n:
            return ['Segment runs %d bytes past the end of the file: truncated, so it cannot be checked' % (end - n)]
        if end < n:
            out.append('%d bytes behind the Segment: appended data cannot be checked' % (n - end))
        pos = start
        while pos < end and len(out) < MAX_BOX_FINDINGS:
            el = ebml_element(f, pos)
            if not el:
                return out + ['malformed element at byte %d inside the Segment, so its elements cannot be checked' % pos]
            if el[1] < 0:
                return out + ['element of unknown size inside the Segment at byte %d: it cannot be checked' % pos]
            if el[0] == EBML_ATTACHMENTS:
                out.append('Attachments element at the Segment top level (attached files can carry EXIF and XMP)')
            if pos + el[2] + el[1] > end:
                return out + ['element at byte %d runs past the Segment, so its elements cannot be checked' % pos]
            pos += el[2] + el[1]
    return out


def probe_findings(path, mov):
    cmd = ['ffprobe', '-v', 'error']
    if mov:
        cmd += ['-export_xmp', '1', '-export_all', '1']
    cmd += ['-show_format', '-show_streams', '-show_chapters', '-of', 'json', 'file:' + os.path.abspath(path)]
    try:
        run = subprocess.run(cmd, capture_output=True, timeout=120, check=False)
    except subprocess.TimeoutExpired:
        return ['ffprobe timed out, so its metadata cannot be checked']
    if run.returncode != 0:
        why = run.stderr.decode('utf-8', 'replace').strip().splitlines()
        return ['ffprobe could not read it (%s), so its metadata cannot be checked'
                % (why[-1] if why else 'exit %d' % run.returncode)]
    try:
        info = json.loads(run.stdout.decode('utf-8', 'replace'))
    except ValueError:
        return ['ffprobe printed something that is not JSON, so its metadata cannot be checked']
    out = tag_findings('container', (info.get('format') or {}).get('tags'))
    for s in info.get('streams') or []:
        what = 'stream %s (%s)' % (s.get('index', '?'), s.get('codec_type', '?'))
        out += tag_findings(what, s.get('tags'))
        if s.get('codec_type') not in ('video', 'audio'):
            out.append('%s, codec %s, tag %s: a track that is not video or audio can hold telemetry'
                       % (what, s.get('codec_name', '?'), s.get('codec_tag_string', '?')))
        elif (s.get('disposition') or {}).get('attached_pic'):
            out.append('%s, codec %s: an attached picture (cover art), which can carry EXIF; ffmpeg -map 0:V leaves it out'
                       % (what, s.get('codec_name', '?')))
    for c in info.get('chapters') or []:
        out += tag_findings('chapter %s' % c.get('id', '?'), c.get('tags'))
    return out


def bmff_findings(path):
    out, brands = bmff_boxes(path)
    images = sorted({b.decode('latin-1') for b in brands if b in IMAGE_BRANDS})
    if images:
        return out + ['brand %s: an HEIF or AVIF still image, whose EXIF and XMP items ffprobe cannot show, '
                      'so it is not read here: convert it to WebP, JPEG or PNG' % ', '.join(images)]
    return out + probe_findings(path, True)


# --- files that are not media: binary is refused, text is searched ---------------
DATA_URI = re.compile(rb'data:(image|video|audio)/', re.I)
SVG_META = ((re.compile(rb'<metadata', re.I), '<metadata element'),
            (re.compile(rb'sodipodi:', re.I), 'sodipodi: editor attributes'),
            (re.compile(rb'inkscape:', re.I), 'inkscape: editor attributes'),
            (re.compile(rb'xmlns:rdf', re.I), 'xmlns:rdf (RDF metadata)'))


def has_nul(path):
    with open(path, 'rb') as f:
        while True:
            chunk = f.read(1 << 20)
            if not chunk:
                return False
            if b'\x00' in chunk:
                return True


def text_findings(path, ext):
    """Inline media and, in an SVG, editor and RDF metadata: the construct and its first line."""
    if os.path.getsize(path) > MAX_STILL:
        return ['larger than %d MiB, so it is not read into memory and cannot be checked' % (MAX_STILL >> 20)]
    rules = [(DATA_URI, 'inline data: URI of an image, video or audio (not decoded here)')]
    if ext == '.svg':
        rules += [(rx, what) for rx, what in SVG_META]
    first = {}
    count = {}
    with open(path, 'rb') as f:
        for lineno, line in enumerate(f, 1):
            for rx, what in rules:
                hits = len(rx.findall(line))
                if hits:
                    first.setdefault(what, lineno)
                    count[what] = count.get(what, 0) + hits
    return ['%s at line %d%s' % (what, first[what], ' (%d times)' % count[what] if count[what] > 1 else '')
            for _, what in rules if what in first]


def skipped_findings(path, ext):
    if has_nul(path):
        return ['binary file of an unchecked type: it holds a NUL byte and is not media this check reads, '
                'so what it carries cannot be checked']
    return text_findings(path, ext) if ext in TEXT_EXT else []


# --- what is a file --------------------------------------------------------
def classify(path, ext):
    """(kind, note): kind is jpeg png webp gif bmff ebml, refuse or skip."""
    if ext in SIDECAR_EXT:
        return 'refuse', ('%s is a camera proxy, thumbnail or telemetry sidecar (GPS and EXIF travel with it) '
                          'and is not read here: do not publish it' % ext)
    with open(path, 'rb') as f:
        head = f.read(400)
    if head[:3] == b'\xff\xd8\xff':
        return 'jpeg', ''
    if head[:8] == MAGIC_PNG:
        return 'png', ''
    if head[:4] == b'RIFF' and head[8:12] == b'WEBP':
        return 'webp', ''
    if head[:4] == b'GIF8':
        return 'gif', ''
    if head[4:8] == b'ftyp':
        return 'bmff', ''
    if head[:4] == b'\x1a\x45\xdf\xa3':
        return 'ebml', ''
    for sig, name in OTHER_MEDIA:
        if head.startswith(sig):
            return 'refuse', '%s is a media container that is not read here, so its metadata cannot be checked' % name
    if head[:4] == b'RIFF':
        return 'refuse', 'a RIFF container (AVI or WAVE) is not read here, so its metadata cannot be checked'
    if len(head) > 376 and head[0] == head[188] == head[376] == 0x47:
        return 'refuse', 'an MPEG transport stream is not read here, so its metadata cannot be checked'
    if ext in STILL_EXT or ext in VIDEO_EXT or ext in UNCHECKED_EXT:
        return 'refuse', ('its name says %s but its first bytes are not that format, or any format read here, '
                          'so its metadata cannot be checked' % ext)
    return 'skip', 'not an image or a video'


def findings_for(path, kind, note):
    if kind == 'refuse':
        return [note]
    if kind in ('jpeg', 'png', 'webp', 'gif'):
        if os.path.getsize(path) > MAX_STILL:
            return ['larger than %d MiB, so it is not read into memory and its metadata cannot be checked' % (MAX_STILL >> 20)]
        with open(path, 'rb') as f:
            data = f.read()
        return {'jpeg': jpeg_findings, 'png': png_findings, 'webp': webp_findings, 'gif': gif_findings}[kind](data)
    if kind == 'bmff':
        return bmff_findings(path)
    return ebml_findings(path) + probe_findings(path, False)      # ebml


def main(argv):
    # A file name that is not valid UTF-8 must be printed, not crash the check
    # with an exit status that reads as "findings".
    sys.stdout.reconfigure(errors='backslashreplace')
    sys.stderr.reconfigure(errors='backslashreplace')
    verbose = False
    paths = []
    for a in argv[1:]:
        if a in ('-h', '--help'):
            print(__doc__)
            return 0
        if a in ('-v', '--verbose'):
            verbose = True
        elif a.startswith('-'):
            print('usage: check-media-metadata.py [-v] PATH...', file=sys.stderr)
            return 2
        else:
            paths.append(a)
    if not paths:
        print('usage: check-media-metadata.py [-v] PATH...', file=sys.stderr)
        return 2

    def unreadable(e):
        raise e

    files = []
    odd = []                                      # links and other files that are not plain
    for p in paths:
        if len(p) > 1:                            # "dl/" would resolve a link "dl" in lstat
            p = p.rstrip(os.sep) or os.sep
        st = os.lstat(p)
        if stat.S_ISDIR(st.st_mode):
            for root, dirs, names in os.walk(p, onerror=unreadable):
                dirs.sort()
                for d in list(dirs):
                    if os.path.islink(os.path.join(root, d)):
                        odd.append((os.path.join(root, d), 'symbolic link, never followed, so what it points to is not checked'))
                        dirs.remove(d)
                for name in sorted(names):
                    full = os.path.join(root, name)
                    mode = os.lstat(full).st_mode
                    if stat.S_ISREG(mode):
                        files.append(full)
                    elif stat.S_ISLNK(mode):
                        odd.append((full, 'symbolic link, never followed, so what it points to is not checked'))
                    else:
                        odd.append((full, 'not a plain file, so it is not opened'))
        elif stat.S_ISREG(st.st_mode):
            files.append(p)
        elif stat.S_ISLNK(st.st_mode):
            odd.append((p, 'symbolic link, never followed, so what it points to is not checked'))
        else:
            odd.append((p, 'not a plain file, so it is not opened'))

    plan = []
    for f in files:
        try:
            kind, note = classify(f, os.path.splitext(f)[1].lower())
        except OSError as e:
            kind, note = 'refuse', 'cannot be read (%s)' % e.strerror
        plan.append((f, kind, note))
    if any(kind in ('bmff', 'ebml') for _, kind, _ in plan) and not shutil.which('ffprobe'):
        print('check-media-metadata.py: ffprobe is not on PATH, and it is needed to read video metadata', file=sys.stderr)
        return 2

    refused = 0
    clean = 0
    skipped = 0
    for p, why in odd:
        print('%s: %s' % (p, why))
        refused += 1
    for f, kind, note in plan:
        try:
            if kind == 'skip':
                found = skipped_findings(f, os.path.splitext(f)[1].lower())
                if not found:
                    skipped += 1
                    if verbose:
                        print('skip  %s (%s)' % (f, note))
                    continue
            else:
                found = findings_for(f, kind, note)
        except OSError as e:
            found = ['cannot be read (%s)' % e.strerror]
        if found:
            refused += 1
            for why in found[:MAX_LINES]:
                print('%s: %s' % (f, why))
            if len(found) > MAX_LINES:
                print('%s: ... and %d more findings' % (f, len(found) - MAX_LINES))
        else:
            clean += 1
            if verbose:
                print('ok  %s' % f)
    if verbose:
        print('checked %d images and videos: %d clean, %d refused; %d other files skipped'
              % (clean + refused, clean, refused, skipped))
    return 1 if refused else 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv))
    except OSError as e:
        print('check-media-metadata.py: %s: %s' % (e.filename, e.strerror), file=sys.stderr)
        sys.exit(2)
