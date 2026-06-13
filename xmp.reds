Red/System [
    Title:   "protracker-red — libxmp binding"
    Author:  "Nenad Rakocevic"
    Purpose: {
        Thin Red/System binding for libxmp 4.7 (the Extended Module Player
        decoding library, MIT-licensed). Only the playback-relevant entry
        points, plus offset-based accessors for the xmp_frame_info /
        xmp_module structures that carry the per-channel volume + note data
        the visualiser needs.

        libxmp only DECODES a module into PCM; audio output is done elsewhere
        (audio.reds). xmp_play_frame renders one replay tick into
        frame_info.buffer (buffer_size bytes, signed 16-bit stereo at the rate
        passed to xmp_start_player).

        Struct field offsets are read by hand (Red/System struct! can't express
        the embedded channel_info[64] array). All offsets verified against
        libxmp/include/xmp.h @ 4.7.0 on a 32-bit (x86) target.
    }
]

;-- ============================================================
;--  Constants (see include/xmp.h)
;-- ============================================================

#define XMP-END                 1               ;-- xmp_play_frame: module ended
#define XMP-NAME-SIZE           64
#define XMP-MAX-CHANNELS        64
#define XMP-FRAME-INFO-SIZE     1616            ;-- 72 header + 64*24 channels = 1608, rounded up
#define XMP-MODULE-INFO-SIZE    64              ;-- struct is 36 bytes; over-allocate
#define XMP-TEST-INFO-SIZE      128             ;-- char name[64] + char type[64]

;-- xmp_start_player format flags (0 = default: signed 16-bit, stereo)
#define XMP-FORMAT-8BIT         1
#define XMP-FORMAT-UNSIGNED     2
#define XMP-FORMAT-MONO         4

;-- player parameters / modes
#define XMP-PLAYER-MODE         11
#define XMP-PLAYER-INTERP       2
#define XMP-PLAYER-AMP          0
#define XMP-MODE-AUTO           0
#define XMP-MODE-PROTRACKER     3
#define XMP-INTERP-SPLINE       2

;-- xmp_event field selectors for XMP-EVENT
#define XMP-EV-NOTE             0
#define XMP-EV-INS              1
#define XMP-EV-VOL              2
#define XMP-EV-FXT              3
#define XMP-EV-FXP              4

;-- ============================================================
;--  xmp_frame_info header (first 18 fields = 72 bytes).
;--  channel_info[XMP_MAX_CHANNELS] follows at byte offset 72.
;-- ============================================================
xmp-frame-info!: alias struct! [
    pos           [integer!]
    pattern       [integer!]
    row           [integer!]
    num-rows      [integer!]
    frame         [integer!]
    speed         [integer!]
    bpm           [integer!]
    time          [integer!]
    total-time    [integer!]
    frame-time    [integer!]
    buffer        [byte-ptr!]                   ;-- void* PCM
    buffer-size   [integer!]
    total-size    [integer!]
    volume        [integer!]
    loop-count    [integer!]
    virt-channels [integer!]
    virt-used     [integer!]
    sequence      [integer!]
]

;-- ============================================================
;--  Imports
;-- ============================================================
#import [
    "libxmp" cdecl [
        xmp_create_context:  "xmp_create_context"  [ return: [int-ptr!] ]
        xmp_free_context:    "xmp_free_context"     [ ctx [int-ptr!] ]
        xmp_test_module:     "xmp_test_module"      [ path [c-string!] info [int-ptr!] return: [integer!] ]
        xmp_load_module:     "xmp_load_module"      [ ctx [int-ptr!] path [c-string!] return: [integer!] ]
        xmp_load_module_from_memory: "xmp_load_module_from_memory" [ ctx [int-ptr!] mem [int-ptr!] size [integer!] return: [integer!] ]
        xmp_test_module_from_memory: "xmp_test_module_from_memory" [ mem [int-ptr!] size [integer!] info [int-ptr!] return: [integer!] ]
        xmp_release_module:  "xmp_release_module"   [ ctx [int-ptr!] ]
        xmp_start_player:    "xmp_start_player"     [ ctx [int-ptr!] rate [integer!] format [integer!] return: [integer!] ]
        xmp_end_player:      "xmp_end_player"       [ ctx [int-ptr!] ]
        xmp_play_frame:      "xmp_play_frame"       [ ctx [int-ptr!] return: [integer!] ]
        xmp_get_frame_info:  "xmp_get_frame_info"   [ ctx [int-ptr!] info [int-ptr!] ]
        xmp_get_module_info: "xmp_get_module_info"  [ ctx [int-ptr!] info [int-ptr!] ]
        xmp_set_position:    "xmp_set_position"     [ ctx [int-ptr!] pos [integer!] return: [integer!] ]
        xmp_seek_time:       "xmp_seek_time"        [ ctx [int-ptr!] time [integer!] return: [integer!] ]
        xmp_next_position:   "xmp_next_position"    [ ctx [int-ptr!] return: [integer!] ]
        xmp_prev_position:   "xmp_prev_position"    [ ctx [int-ptr!] return: [integer!] ]
        xmp_restart_module:  "xmp_restart_module"   [ ctx [int-ptr!] ]
        xmp_stop_module:     "xmp_stop_module"      [ ctx [int-ptr!] ]
        xmp_set_player:      "xmp_set_player"        [ ctx [int-ptr!] param [integer!] val [integer!] return: [integer!] ]
        xmp_get_player:      "xmp_get_player"        [ ctx [int-ptr!] param [integer!] return: [integer!] ]
        xmp_channel_mute:    "xmp_channel_mute"      [ ctx [int-ptr!] chan [integer!] val [integer!] return: [integer!] ]
    ]
]

;-- ============================================================
;--  Low-level peek helpers (offsets are byte offsets from a base
;--  byte-ptr!; pointer indexing in Red/System is 1-based).
;-- ============================================================
peek-i32: func [ b [byte-ptr!] ofs [integer!] return: [integer!] /local q [byte-ptr!] p [int-ptr!] ][
    q: b + ofs
    p: as int-ptr! q
    p/value
]

peek-u8: func [ b [byte-ptr!] ofs [integer!] return: [integer!] /local p [byte-ptr!] ][
    p: b + ofs
    as integer! p/value
]

;-- channel_info[i] lives at 72 + i*24; field is the byte offset within it
chan-off: func [ i [integer!] field [integer!] return: [integer!] ][
    72 + (i * 24) + field
]

;-- ============================================================
;--  Per-channel accessors (fi = byte-ptr! to a filled frame_info)
;-- ============================================================
xmp-chan-vol:    func [ fi [byte-ptr!] i [integer!] return: [integer!] ][ peek-u8  fi (chan-off i 13) ]   ;-- 0..vol_base
xmp-chan-note:   func [ fi [byte-ptr!] i [integer!] return: [integer!] ][ peek-u8  fi (chan-off i 10) ]   ;-- 0 = none
xmp-chan-ins:    func [ fi [byte-ptr!] i [integer!] return: [integer!] ][ peek-u8  fi (chan-off i 11) ]
xmp-chan-sample: func [ fi [byte-ptr!] i [integer!] return: [integer!] ][ peek-u8  fi (chan-off i 12) ]
xmp-chan-pan:    func [ fi [byte-ptr!] i [integer!] return: [integer!] ][ peek-u8  fi (chan-off i 14) ]
xmp-chan-period: func [ fi [byte-ptr!] i [integer!] return: [integer!] ][ peek-i32 fi (chan-off i 0)  ]

;-- ============================================================
;--  Module-info / module accessors
;--  mi = byte-ptr! to xmp_module_info ; m = byte-ptr! to xmp_module
;-- ============================================================
xmp-modinfo-volbase: func [ mi [byte-ptr!] return: [integer!] ][ peek-i32 mi 16 ]

xmp-modinfo-mod: func [ mi [byte-ptr!] return: [byte-ptr!] /local p [int-ptr!] ][
    p: as int-ptr! (mi + 20)
    as byte-ptr! p/value
]

xmp-mod-name: func [ m [byte-ptr!] return: [c-string!] ][ as c-string! m ]
xmp-mod-type: func [ m [byte-ptr!] return: [c-string!] ][ as c-string! (m + 64) ]
xmp-mod-npat: func [ m [byte-ptr!] return: [integer!] ][ peek-i32 m 128 ]
xmp-mod-chn:  func [ m [byte-ptr!] return: [integer!] ][ peek-i32 m 136 ]
xmp-mod-ins:  func [ m [byte-ptr!] return: [integer!] ][ peek-i32 m 140 ]
xmp-mod-smp:  func [ m [byte-ptr!] return: [integer!] ][ peek-i32 m 144 ]
xmp-mod-len:  func [ m [byte-ptr!] return: [integer!] ][ peek-i32 m 156 ]   ;-- length in orders

;-- xmp_sample[i].name : xxs (xmp_sample*) at m+180, each sample = 52 bytes, name @ +0
xmp-sample-name: func [ m [byte-ptr!] i [integer!] return: [c-string!] /local xxs [int-ptr!] ][
    xxs: as int-ptr! (peek-i32 m 180)
    if null? xxs [ return "" ]
    as c-string! ((as byte-ptr! xxs) + (i * 52))
]

;-- One byte of pattern `pat`, channel `chn`, row `row`:
;--   mod->xxp[pat]->index[chn] -> mod->xxt[trk]->event[row].<field>
xmp-event: func [
    m     [byte-ptr!]
    pat   [integer!]
    chn   [integer!]
    row   [integer!]
    field [integer!]
    return: [integer!]
    /local xxp [int-ptr!] xxt [int-ptr!] patp [byte-ptr!] trkp [byte-ptr!] trk [integer!]
][
    xxp: as int-ptr! (peek-i32 m 168)
    if null? xxp [ return 0 ]
    patp: as byte-ptr! (peek-i32 (as byte-ptr! xxp) (pat * 4))   ;-- xxp[pat]
    if null? patp [ return 0 ]
    trk: peek-i32 patp (4 + (chn * 4))                           ;-- index[chn]
    xxt: as int-ptr! (peek-i32 m 172)
    if null? xxt [ return 0 ]
    trkp: as byte-ptr! (peek-i32 (as byte-ptr! xxt) (trk * 4))   ;-- xxt[trk]
    if null? trkp [ return 0 ]
    peek-u8 trkp (4 + (row * 8) + field)                         ;-- event[row].field
]
