Red [
    Title:  "CherryTracker — module player"
    Author: "Nenad Rakocevic"
    Needs:  'View
    Icon:   %assets/cherry.ico
]

;===============================================================================
;  Red/System core : libxmp + SDL bindings, player state, pump + sync
;===============================================================================
#system-global [
    #include %xmp.reds
    #include %audio.reds

    #define PT-RING-DEPTH 256                 ;-- snapshot ring slots (covers buffer-ahead)
    #define PT-SCOPE-N    128                 ;-- oscilloscope points per frame
    #define PT-QTARGET    70560               ;-- keep ~0.4 s (bytes) buffered in SDL
    #define PT-NB         48                  ;-- spectrum-analyzer bands (Goertzel)
    #define PT-FFT-N      512                 ;-- samples analysed per frame

    ;-- handles + buffers
    pt-ctx:    as int-ptr!  0
    pt-strm:   as int-ptr!  0
    pt-fib:    as byte-ptr! 0                  ;-- xmp_frame_info buffer
    pt-fi:     as xmp-frame-info! 0
    pt-mib:    as byte-ptr! 0                  ;-- xmp_module_info buffer
    pt-modp:   as byte-ptr! 0                  ;-- xmp_module*
    pt-spec:   declare SDL-AudioSpec!
    pt-vbase:  64
    pt-nchan:  4

    ;-- flags
    pt-inited?:  no
    pt-opened?:  no
    pt-loaded?:  no
    pt-ended?:   no
    pt-loopf?:   no

    ;-- audio byte accounting
    pt-total:  0                               ;-- total bytes ever pushed to SDL
    pt-dur:    0                               ;-- module duration in ms (at open)

    ;-- snapshot ring (parallel arrays) ------------------------------------
    pt-rb-end:   as int-ptr!  0
    pt-rb-pos:   as int-ptr!  0
    pt-rb-pat:   as int-ptr!  0
    pt-rb-row:   as int-ptr!  0
    pt-rb-nrows: as int-ptr!  0
    pt-rb-bpm:   as int-ptr!  0
    pt-rb-spd:   as int-ptr!  0
    pt-rb-gvol:  as int-ptr!  0
    pt-rb-time:  as int-ptr!  0
    pt-rb-vol:   as byte-ptr! 0                 ;-- depth * 64
    pt-rb-note:  as byte-ptr! 0                 ;-- depth * 64
    pt-rb-scope: as byte-ptr! 0                 ;-- depth * PT-SCOPE-N
    pt-head:   0                                ;-- absolute write counter
    pt-tail:   0                                ;-- absolute read counter

    ;-- current (synced) snapshot, read by the getters
    pt-cur-pos:   0
    pt-cur-pat:   0
    pt-cur-row:   0
    pt-cur-nrows: 0
    pt-cur-bpm:   0
    pt-cur-spd:   0
    pt-cur-gvol:  0
    pt-cur-time:  0
    pt-cv:  as byte-ptr! 0                      ;-- 64 current channel vols
    pt-cn:  as byte-ptr! 0                      ;-- 64 current channel notes
    pt-cs:  as byte-ptr! 0                      ;-- PT-SCOPE-N current scope

    ;-- spectrum analyzer (Goertzel) : float arrays
    pt-spec-coeff: as pointer! [float!] 0       ;-- PT-NB filter coeffs (2*cos w), from Red
    pt-spec-mag:   as pointer! [float!] 0       ;-- PT-NB current band magnitudes (squared)
    pt-fft-buf:    as pointer! [float!] 0       ;-- PT-FFT-N mono scratch samples
    pt-spec-win:   as pointer! [float!] 0       ;-- PT-FFT-N Hann window, from Red

    ;-- typed array element access -----------------------------------------
    pt-geti: func [ arr [int-ptr!]  k [integer!] return: [integer!] /local p [int-ptr!]  ][ p: arr + k  p/value ]
    pt-seti: func [ arr [int-ptr!]  k [integer!] v [integer!]       /local p [int-ptr!]  ][ p: arr + k  p/value: v ]
    pt-getb: func [ arr [byte-ptr!] k [integer!] return: [integer!] /local p [byte-ptr!] ][ p: arr + k  as integer! p/value ]
    pt-setb: func [ arr [byte-ptr!] k [integer!] v [integer!]       /local p [byte-ptr!] ][ p: arr + k  p/value: as byte! v ]
    pt-getf: func [ arr [pointer! [float!]] k [integer!] return: [float!] /local p [pointer! [float!]] ][ p: arr + k  p/value ]
    pt-setf: func [ arr [pointer! [float!]] k [integer!] v [float!]        /local p [pointer! [float!]] ][ p: arr + k  p/value: v ]

    ;-- read a signed little-endian 16-bit sample at byte offset ofs
    pt-read-s16: func [ b [byte-ptr!] ofs [integer!] return: [integer!] /local lo [integer!] hi [integer!] v [integer!] ][
        lo: pt-getb b ofs
        hi: pt-getb b (ofs + 1)
        v: (hi << 8) or lo
        if v >= 32768 [ v: v - 65536 ]
        v
    ]

    ;-- allocate everything once
    pt-rs-init: func [ return: [integer!] /local i [integer!] ][
        pt-ctx: xmp_create_context
        if null? pt-ctx [ return 1 ]
        ;-- SDL3's C bool return marshals unreliably through R/S (only AL is set);
        ;-- ignore it and confirm the audio subsystem via the current-driver string
        SDL_Init SDL-INIT-AUDIO
        if null? SDL_GetCurrentAudioDriver [ return 2 ]
        pt-fib: allocate XMP-FRAME-INFO-SIZE
        pt-fi:  as xmp-frame-info! pt-fib
        pt-mib: allocate XMP-MODULE-INFO-SIZE
        pt-rb-end:   as int-ptr! allocate (PT-RING-DEPTH * 4)
        pt-rb-pos:   as int-ptr! allocate (PT-RING-DEPTH * 4)
        pt-rb-pat:   as int-ptr! allocate (PT-RING-DEPTH * 4)
        pt-rb-row:   as int-ptr! allocate (PT-RING-DEPTH * 4)
        pt-rb-nrows: as int-ptr! allocate (PT-RING-DEPTH * 4)
        pt-rb-bpm:   as int-ptr! allocate (PT-RING-DEPTH * 4)
        pt-rb-spd:   as int-ptr! allocate (PT-RING-DEPTH * 4)
        pt-rb-gvol:  as int-ptr! allocate (PT-RING-DEPTH * 4)
        pt-rb-time:  as int-ptr! allocate (PT-RING-DEPTH * 4)
        pt-rb-vol:   allocate (PT-RING-DEPTH * 64)
        pt-rb-note:  allocate (PT-RING-DEPTH * 64)
        pt-rb-scope: allocate (PT-RING-DEPTH * PT-SCOPE-N)
        pt-cv: allocate 64
        pt-cn: allocate 64
        pt-cs: allocate PT-SCOPE-N
        pt-spec-coeff: as pointer! [float!] allocate (PT-NB * 8)
        pt-spec-mag:   as pointer! [float!] allocate (PT-NB * 8)
        pt-fft-buf:    as pointer! [float!] allocate (PT-FFT-N * 8)
        pt-spec-win:   as pointer! [float!] allocate (PT-FFT-N * 8)
        i: 0  while [ i < 64 ][ pt-setb pt-cv i 0  pt-setb pt-cn i 0  i: i + 1 ]
        i: 0  while [ i < PT-SCOPE-N ][ pt-setb pt-cs i 0  i: i + 1 ]
        i: 0  while [ i < PT-NB ][ pt-setf pt-spec-coeff i 0.0  pt-setf pt-spec-mag i 0.0  i: i + 1 ]
        i: 0  while [ i < PT-FFT-N ][ pt-setf pt-spec-win i 1.0  i: i + 1 ]
        pt-inited?: yes
        0
    ]

    pt-rs-reset-stream: func [][
        if pt-opened? [ SDL_ClearAudioStream pt-strm ]
        pt-total:  0
        pt-head:   0
        pt-tail:   0
        pt-ended?: no
    ]

    ;-- after a module is loaded: read info, start player, open/clear stream
    pt-rs-open: func [ return: [integer!] /local r [integer!] ][
        xmp_get_module_info pt-ctx (as int-ptr! pt-mib)
        pt-modp:  xmp-modinfo-mod pt-mib
        pt-vbase: xmp-modinfo-volbase pt-mib
        pt-nchan: xmp-mod-chn pt-modp
        if pt-vbase <= 0 [ pt-vbase: 64 ]
        if pt-nchan <= 0 [ pt-nchan: 4 ]
        if pt-nchan > 64 [ pt-nchan: 64 ]
        r: xmp_start_player pt-ctx 44100 0
        if r <> 0 [ return r ]
        xmp_get_frame_info pt-ctx (as int-ptr! pt-fib)
        pt-dur: pt-fi/total-time
        if not pt-opened? [
            pt-spec/format:   SDL-AUDIO-S16
            pt-spec/channels: 2
            pt-spec/freq:     44100
            pt-strm: SDL_OpenAudioDeviceStream SDL-AUDIO-DEFAULT-PLAYBACK pt-spec null null
            if null? pt-strm [ return 99 ]
            SDL_ResumeAudioStreamDevice pt-strm
            pt-opened?: yes
        ]
        pt-rs-reset-stream
        0
    ]

    ;-- store the current frame_info into ring slot `pt-head`
    pt-rs-record: func [ /local slot [integer!] i [integer!] base [integer!] nsamp [integer!] idx [integer!] sv [integer!] s8 [integer!] ][
        slot: pt-head // PT-RING-DEPTH
        pt-seti pt-rb-end   slot pt-total
        pt-seti pt-rb-pos   slot pt-fi/pos
        pt-seti pt-rb-pat   slot pt-fi/pattern
        pt-seti pt-rb-row   slot pt-fi/row
        pt-seti pt-rb-nrows slot pt-fi/num-rows
        pt-seti pt-rb-bpm   slot pt-fi/bpm
        pt-seti pt-rb-spd   slot pt-fi/speed
        pt-seti pt-rb-gvol  slot pt-fi/volume
        pt-seti pt-rb-time  slot pt-fi/time
        base: slot * 64
        i: 0
        while [ i < 64 ][
            either i < pt-nchan [
                pt-setb pt-rb-vol  (base + i) (xmp-chan-vol  pt-fib i)
                pt-setb pt-rb-note (base + i) (xmp-chan-note pt-fib i)
            ][
                pt-setb pt-rb-vol  (base + i) 0
                pt-setb pt-rb-note (base + i) 0
            ]
            i: i + 1
        ]
        ;-- decimate left channel into the scope snippet
        nsamp: pt-fi/buffer-size / 4
        base:  slot * PT-SCOPE-N
        i: 0
        while [ i < PT-SCOPE-N ][
            either nsamp > 0 [
                idx: (i * nsamp) / PT-SCOPE-N
                sv:  pt-read-s16 pt-fi/buffer (idx * 4)
                s8:  (sv / 256) + 128
                if s8 < 0   [ s8: 0 ]
                if s8 > 255 [ s8: 255 ]
            ][
                s8: 128
            ]
            pt-setb pt-rb-scope (base + i) s8
            i: i + 1
        ]
        pt-head: pt-head + 1
    ]

    ;-- Goertzel spectrum: PT-NB band magnitudes(^2) from the last frame's PCM
    pt-rs-spectrum: func [ /local n [integer!] j [integer!] i [integer!] iv [integer!]
                                  x [float!] s0 [float!] s1 [float!] s2 [float!] cf [float!] m [float!] bufp [byte-ptr!] ][
        if not pt-opened? [ exit ]
        n: pt-fi/buffer-size / 4
        if n > PT-FFT-N [ n: PT-FFT-N ]
        if n <= 0 [ exit ]
        bufp: pt-fi/buffer
        j: 0
        while [ j < n ][
            iv: pt-read-s16 bufp (j * 4)
            x:  as float! iv
            pt-setf pt-fft-buf j ((x / 32768.0) * (pt-getf pt-spec-win j))   ;-- Hann window
            j: j + 1
        ]
        i: 0
        while [ i < PT-NB ][
            cf: pt-getf pt-spec-coeff i
            s1: 0.0
            s2: 0.0
            j: 0
            while [ j < n ][
                x:  pt-getf pt-fft-buf j
                s0: x + (cf * s1) - s2
                s2: s1
                s1: s0
                j: j + 1
            ]
            m: (s1 * s1) + (s2 * s2) - (cf * s1 * s2)
            pt-setf pt-spec-mag i m
            i: i + 1
        ]
    ]

    ;-- render frames until the SDL queue holds ~PT-QTARGET bytes
    pt-rs-pump: func [ return: [integer!] /local r [integer!] q [integer!] ][
        if not pt-opened? [ return 1 ]
        if pt-ended? [ return 1 ]
        q: SDL_GetAudioStreamQueued pt-strm
        while [ all [ not pt-ended?  q < PT-QTARGET ] ][
            r: xmp_play_frame pt-ctx
            either r = 0 [
                xmp_get_frame_info pt-ctx (as int-ptr! pt-fib)
                either all [ not pt-loopf?  pt-fi/loop-count > 0 ][
                    pt-ended?: yes
                ][
                    SDL_PutAudioStreamData pt-strm pt-fi/buffer pt-fi/buffer-size
                    pt-total: pt-total + pt-fi/buffer-size
                    pt-rs-record
                ]
            ][
                pt-ended?: yes
            ]
            q: SDL_GetAudioStreamQueued pt-strm
        ]
        if not pt-ended? [ pt-rs-spectrum ]
        either pt-ended? [ 1 ][ 0 ]
    ]

    ;-- surface the snapshot that is actually audible right now
    pt-rs-sync: func [ /local played [integer!] q [integer!] best [integer!] k [integer!] slot [integer!] i [integer!] base [integer!] ][
        if not pt-opened? [ exit ]
        q: SDL_GetAudioStreamQueued pt-strm
        played: pt-total - q
        best: -1
        k: pt-tail
        while [ k < pt-head ][
            if (pt-geti pt-rb-end (k // PT-RING-DEPTH)) <= played [ best: k ]
            k: k + 1
        ]
        if best < 0 [ exit ]
        slot: best // PT-RING-DEPTH
        pt-cur-pos:   pt-geti pt-rb-pos   slot
        pt-cur-pat:   pt-geti pt-rb-pat   slot
        pt-cur-row:   pt-geti pt-rb-row   slot
        pt-cur-nrows: pt-geti pt-rb-nrows slot
        pt-cur-bpm:   pt-geti pt-rb-bpm   slot
        pt-cur-spd:   pt-geti pt-rb-spd   slot
        pt-cur-gvol:  pt-geti pt-rb-gvol  slot
        pt-cur-time:  pt-geti pt-rb-time  slot
        base: slot * 64
        i: 0
        while [ i < 64 ][
            pt-setb pt-cv i (pt-getb pt-rb-vol  (base + i))
            pt-setb pt-cn i (pt-getb pt-rb-note (base + i))
            i: i + 1
        ]
        base: slot * PT-SCOPE-N
        i: 0
        while [ i < PT-SCOPE-N ][
            pt-setb pt-cs i (pt-getb pt-rb-scope (base + i))
            i: i + 1
        ]
        pt-tail: best
    ]

    ;-- zero the surfaced visual state (VU vols + spectrum mags) -> bars ease down
    pt-rs-clear-state: func [ /local i [integer!] ][
        pt-cur-pos:  0
        pt-cur-pat:  0
        pt-cur-row:  0
        pt-cur-time: 0
        i: 0
        while [ i < 64 ][
            pt-setb pt-cv i 0
            pt-setb pt-cn i 0
            i: i + 1
        ]
        i: 0
        while [ i < PT-NB ][
            pt-setf pt-spec-mag i 0.0
            i: i + 1
        ]
        i: 0
        while [ i < PT-SCOPE-N ][
            pt-setb pt-cs i 128
            i: i + 1
        ]
    ]
]

;===============================================================================
;  routine! bridges  (Red-callable)
;===============================================================================
pt-init:    routine [ return: [integer!] ][ pt-rs-init ]
pt-pump:    routine [ return: [integer!] ][ pt-rs-pump ]
pt-sync:    routine [ ][ pt-rs-sync ]

pt-load-mem: routine [ bin [binary!] return: [integer!] /local p [byte-ptr!] n [integer!] r [integer!] ][
    if pt-loaded? [
        xmp_end_player     pt-ctx
        xmp_release_module pt-ctx
        pt-loaded?: no
    ]
    p: binary/rs-head bin
    n: binary/rs-length? bin
    r: xmp_load_module_from_memory pt-ctx (as int-ptr! p) n
    if r <> 0 [ return r ]
    pt-loaded?: yes
    pt-rs-open
]

;-- getters (read the synced snapshot)
pt-pos:      routine [ return: [integer!] ][ pt-cur-pos   ]
pt-pattern:  routine [ return: [integer!] ][ pt-cur-pat   ]
pt-row:      routine [ return: [integer!] ][ pt-cur-row   ]
pt-numrows:  routine [ return: [integer!] ][ pt-cur-nrows ]
pt-bpm:      routine [ return: [integer!] ][ pt-cur-bpm   ]
pt-speed:    routine [ return: [integer!] ][ pt-cur-spd   ]
pt-gvol:     routine [ return: [integer!] ][ pt-cur-gvol  ]
pt-time-ms:  routine [ return: [integer!] ][ pt-cur-time  ]
pt-channels: routine [ return: [integer!] ][ pt-nchan     ]
pt-volbase:  routine [ return: [integer!] ][ pt-vbase     ]
pt-cvol:     routine [ i [integer!] return: [integer!] ][ pt-getb pt-cv i ]
pt-cnote:    routine [ i [integer!] return: [integer!] ][ pt-getb pt-cn i ]
pt-scope:    routine [ i [integer!] return: [integer!] ][ pt-getb pt-cs i ]
pt-set-coeff: routine [ i [integer!] c [float!] ][ pt-setf pt-spec-coeff i c ]
pt-set-win:   routine [ i [integer!] w [float!] ][ pt-setf pt-spec-win i w ]
pt-band:      routine [ i [integer!] return: [float!] ][ pt-getf pt-spec-mag i ]
pt-len:      routine [ return: [integer!] ][ either null? pt-modp [ 0 ][ xmp-mod-len  pt-modp ] ]
pt-npat:     routine [ return: [integer!] ][ either null? pt-modp [ 0 ][ xmp-mod-npat pt-modp ] ]
pt-ins:      routine [ return: [integer!] ][ either null? pt-modp [ 0 ][ xmp-mod-ins  pt-modp ] ]
pt-smp:      routine [ return: [integer!] ][ either null? pt-modp [ 0 ][ xmp-mod-smp  pt-modp ] ]
pt-duration: routine [ return: [integer!] ][ pt-dur ]
pt-queued:   routine [ return: [integer!] ][ either pt-opened? [ SDL_GetAudioStreamQueued pt-strm ][ 0 ] ]
pt-clear-state: routine [ ][ pt-rs-clear-state ]

;-- one byte of a pattern cell : field 0=note 1=ins 2=vol 3=fxt 4=fxp
pt-cell: routine [ pat [integer!] chn [integer!] row [integer!] field [integer!] return: [integer!] ][
    either null? pt-modp [ 0 ][ xmp-event pt-modp pat chn row field ]
]

;-- strings
pt-songname: routine [ return: [string!] /local cs [c-string!] ][
    either null? pt-modp [ cs: "" ][ cs: xmp-mod-name pt-modp ]
    string/load-at cs (length? cs) (as cell! stack/arguments) UTF-8
]
pt-modtype: routine [ return: [string!] /local cs [c-string!] ][
    either null? pt-modp [ cs: "" ][ cs: xmp-mod-type pt-modp ]
    string/load-at cs (length? cs) (as cell! stack/arguments) UTF-8
]

;-- transport
pt-stop:    routine [ ][ pt-rs-reset-stream ]
pt-restart: routine [ ][ xmp_restart_module pt-ctx  pt-rs-reset-stream ]
pt-setpos:  routine [ n [integer!] ][ xmp_set_position pt-ctx n  pt-rs-reset-stream ]
pt-next:    routine [ ][ xmp_next_position pt-ctx  pt-rs-reset-stream ]
pt-prev:    routine [ ][ xmp_prev_position pt-ctx  pt-rs-reset-stream ]
pt-seek:    routine [ ms [integer!] ][ xmp_seek_time pt-ctx ms  pt-rs-reset-stream ]
pt-pause-dev:  routine [ ][ if pt-opened? [ SDL_PauseAudioStreamDevice  pt-strm ] ]
pt-resume-dev: routine [ ][ if pt-opened? [ SDL_ResumeAudioStreamDevice pt-strm ] ]
pt-set-loop: routine [ v [integer!] ][ either v = 0 [ pt-loopf?: no ][ pt-loopf?: yes ] ]
pt-set-gain: routine [ g [float!] ][ if pt-opened? [ SDL_SetAudioStreamGain pt-strm (as float32! g) ] ]   ;-- output gain, leaves the meters honest

pt-quit: routine [ ][
    if pt-loaded? [ xmp_end_player pt-ctx  xmp_release_module pt-ctx ]
    if not null? pt-ctx [ xmp_free_context pt-ctx ]
    if pt-opened? [ SDL_DestroyAudioStream pt-strm ]
    SDL_Quit
]

;===============================================================================
;  CherryTracker UI  (FlodPro-style Draw layout, 1024x768 real pixels)
;===============================================================================

;-- palette : FlodPro chrome — medium gray, fine 1px bezels on EVERY element,
;-- WHITE labels, sunken GRAY value cells with dark data text (no black text boxes)
col-bg:        158.160.166
col-bevel-lt:  216.218.226
col-bevel-dk:   72.74.84
col-face-dn:   140.142.150        ;-- pressed button face
col-data-bg:     8.8.12           ;-- dark panels : pattern + spectrum wells only
col-data-edge:  58.62.80
col-ink:        18.18.24          ;-- data text in gray cells
col-dim:        92.94.104         ;-- disabled button labels
col-white:     248.249.253        ;-- labels + enabled button text
col-note:      104.138.255        ;-- pattern text (FlodPro blue)
col-row-hi-bg:  44.56.118
col-row-hi-tx: 255.255.255
col-vu-green:   58.228.92
col-vu-yellow: 238.220.60
col-vu-orange: 248.150.46
col-vu-red:    240.66.52
col-vu-dark:    30.36.54
col-vu-well:    10.12.18          ;-- near-black recessed frame behind each VU bar
col-vu-cap:    188.192.200        ;-- spectrum peak cap base
col-accent:    250.182.64
col-cherry-t:  202.80.92          ;-- wordmark : cherry red, top of the glyph shade
col-cherry-b:  142.38.50          ;-- ... bottom
col-stem-t:    128.148.66         ;-- wordmark : olive stem green, top
col-stem-b:     84.104.38         ;-- ... bottom

;-- fonts (sized for the 1024x768 design space)
fnt-logo: make font! [name: "Consolas" size: 24 style: 'bold]
fnt-lbl:  make font! [name: "Consolas" size: 13 style: 'bold]
fnt-val:  make font! [name: "Consolas" size: 15 style: 'bold]
fnt-btn:  make font! [name: "Consolas" size: 14 style: 'bold]
fnt-icon: make font! [name: "Segoe UI Symbol" size: 15 style: 'bold]
fnt-icon-big: make font! [name: "Segoe UI Symbol" size: 20 style: 'bold]   ;-- ↻ renders small : upsize it
fnt-note: make font! [name: "Segoe UI Symbol" size: 20 style: 'bold]   ;-- 🎶 wordmark flourish : MONOCHROME via Segoe UI Symbol, so it takes the gradient pen (Segoe UI Emoji would force colour)
fnt-pat:  make font! [name: "Consolas" size: 14]
fnt-chan: make font! [name: "Consolas" size: 11 style: 'bold]   ;-- CH numbers shrunk for narrow columns (many-channel modules)


;-- layout (1024 x 768 design) : every region is an origin + size pair ---------
win-size: 1024x768
hd-org:   8x6          ;-- header bar
hd-size:  1008x44
pp-org:   8x58         ;-- param panel (left) : 9 rows of label + value box
pp-size:  348x232
bt-org:   364x58       ;-- button grid (2 rows x 4 cols)
btn-size: 158x26
sp-org:   364x124      ;-- spectrum analyzer
sp-size:  652x166
nm-org:   8x298        ;-- 3 name rows : Song / File / Tracker
nm-size:  1008x84
nm-rh:    28           ;-- name row stride (row strip is 26 high)
ch-org:   8x390        ;-- per-channel columns + row gutter
ch-size:  1008x370
;-- param-panel column grid : value cells span x 132..342 (Position cell starts
;-- after its spinners); the Volume row locks to the SAME grid — groove left
;-- edge at 132, value cell right edge at 342
vol-org:  132x264      ;-- volume slider groove (param panel's Volume row)
vol-size: 158x12
seek-org: 600x305      ;-- song seek slider groove (Song name row)
seek-size: 330x12
spin-size: 18x20       ;-- position spinner buttons
spin-l-org: 132x66
spin-r-org: 152x66

;-- transport buttons : single source of truth for drawing AND hit-testing
btns: reduce [
    "PLAY"  364x58
    "PAUSE" 528x58
    "STOP"  692x58
    "LOOP"  856x58
    "PREV"  364x90
    "NEXT"  528x90
    "LOAD"  692x90
    "PLAYLIST" 856x90
]
;-- reserved for the upcoming playlist support : drawn disabled, never act
btn-reserved: ["PREV" "NEXT" "PLAYLIST"]

SPEC-NB:   48          ;-- must match PT-NB
SPEC-FMIN: 55.0
SPEC-FMAX: 12000.0
;-- display calibration, fitted to measured per-band stats (elekfunk + space_debris,
;-- 14 s each) : real content slopes ~3 log10 units across the range; HALF-flatten it
;-- so lows keep dominating and highs only fire on true transients (FlodPro look).
;-- Floor 0.3 sits above the 8-bit sample noise bed (top-band medians -3..-1 + tilt).
SPEC-LO:   0.3         ;-- log10(mag^2) display floor
SPEC-HI:   3.6         ;-- log10(mag^2) display ceiling
SPEC-TILT: 1.5         ;-- progressive HF boost, log10 units across the range (~ +1.9 dB/oct)
SPEC-SAMPLES: 512      ;-- analysis window length, must match PT-FFT-N
SPEC-CAP-HOLD: 30      ;-- peak-cap HOLD : frames the cap stays pinned at a new
                       ;-- peak before it resumes its (unchanged) fall — ~0.5s
                       ;-- @60fps; the "lag" of a real peak-hold meter

;-- spectrum geometry : the dark well hugs the bar field EXACTLY (2px breathing,
;-- same as the inter-bar gaps) so no leftover black columns appear at the edges;
;-- the integer-division remainder is absorbed by the surrounding gray chrome
spec-bw:   to integer! ((sp-size/x - 20) / SPEC-NB)
spec-used: (SPEC-NB * spec-bw) - 2
spec-well: as-pair (sp-org/x + to integer! ((sp-size/x - spec-used) / 2)) (sp-org/y + 10)
spec-fh:   sp-size/y - 20
VU-ATTACK: 33          ;-- VU ballistics : % of the gap eased per frame when rising
VU-DECAY:  11          ;-- ... and when falling (slow decay = classic pumping meters)

SCOPE-N: 128
NOTE-NAMES: ["C-" "C#" "D-" "D#" "E-" "F-" "F#" "G-" "G#" "A-" "A#" "B-"]
HEXD: "0123456789ABCDEF"
FXCH: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
OCT-BASE: 0

;-- state ------------------------------------------------------------------
;-- player state machine : idle | playing | paused | draining | winddown
;--   draining = module decoded to its end, SDL queue still playing the tail
;--   winddown = bars easing down + rows scrolling out of view, then idle
state:      'idle
closing?:   no                  ;-- latched by the window's on-close actor
timer-on?:  no                  ;-- a `rate` timer is armed ONLY during a move/resize drag
name-cache: "(no module)"
type-cache: ""
file-cache: ""
size-cache: ""
file-line:  "  "                ;-- file row text, rebuilt by load-file
loaded?:    no
loop?:      no
volume:     50
vol-drag?:  no
seek-drag?: no
btn-pressed: none
spin-press:  none
last-seek-ms: 0
wind-row:   0
wind-tick:  0
view-pat:   -1                  ;-- what the pattern area displays (real or virtual)
view-row:   0
view-nrows: 0
last-pat:   -1
last-row:   -1
last-nch:   -1
vu-level:   append/dup make block! 64 0 64
spec-peak:  append/dup make block! 64 0 64
spec-level: append/dup make block! 64 0 64
spec-phold: append/dup make block! 64 0 64   ;-- per-band peak-cap hold counter

;-- measured font metrics (average advance per char, set by measure-fonts;
;-- the literals are conservative fallbacks if size-text is unavailable)
aw-logo: 16.8
aw-val:  10.4
aw-lbl:   9.0
aw-btn:   9.6
aw-pat:   8.4
aw-chan:  7.6                     ;-- narrow-column CH-number advance (fnt-chan)
th-logo: 38                      ;-- measured line-box heights (for vertical centering)
th-val:  24
th-lbl:  20
th-btn:  22
th-pat:  19
tb-w:     78                     ;-- time cell width (fits "-00:00")
tb-x:     930                    ;-- time cell x (right-aligned in the name rows)

scratch: make face! [
    type: 'base
    size: 600x60
    visible?: no
]
text-size: func [fnt str /local sz][
    scratch/font: fnt
    scratch/text: str
    sz: attempt [ size-text scratch ]
    either sz [ sz ][ 0x0 ]
]
;-- y offset that vertically centers a line box of height `th` in a cell of height `ch`
cen-y: func [ch th][
    to integer! ((ch - th) / 2)
]
measure-fonts: does [
    sz: text-size fnt-logo "00000000"
    if sz/x > 0 [
        aw-logo: sz/x / 8.0
        th-logo: sz/y
    ]
    sz: text-size fnt-val "00000000"
    if sz/x > 0 [
        aw-val: sz/x / 8.0
        th-val: sz/y
    ]
    sz: text-size fnt-lbl "00000000"
    if sz/x > 0 [
        aw-lbl: sz/x / 8.0
        th-lbl: sz/y
    ]
    sz: text-size fnt-btn "00000000"
    if sz/x > 0 [
        aw-btn: sz/x / 8.0
        th-btn: sz/y
    ]
    sz: text-size fnt-pat "00000000"
    if sz/x > 0 [
        aw-pat: sz/x / 8.0
        th-pat: sz/y
    ]
    sz: text-size fnt-chan "00000000"
    if sz/x > 0 [ aw-chan: sz/x / 8.0 ]
    ;-- derive the time-cell + seek-groove geometry from the real glyph width
    tb-w: 16 + to integer! (aw-val * 6)
    tb-x: nm-org/x + nm-size/x - 8 - tb-w
    seek-size: as-pair (tb-x - 12 - seek-org/x) seek-size/y
]

;-- helpers --------------------------------------------------------------------
;-- one-time builders, used to fill the string tables below; the render loop
;-- itself never builds a string (see the zero-allocation note before render)

pad2: func [n][ either n < 10 [ rejoin ["0" n] ][ form n ] ]

hex2: func [v /local hi lo][
    if v < 0 [ v: 0 ]
    hi: to integer! (v / 16)
    lo: v - (hi * 16)
    rejoin [ HEXD/(hi + 1) HEXD/(lo + 1) ]
]
note-name: func [n /local oct idx][
    case [
        n = 0    [ "..." ]
        n >= 128 [ "===" ]
        true [
            oct: to integer! ((n - 1) / 12)
            idx: (n - 1) - (oct * 12)
            rejoin [ NOTE-NAMES/(idx + 1) (oct + OCT-BASE) ]
        ]
    ]
]
fx-type: func [t][ either all [ t >= 0  t <= 35 ] [ FXCH/(t + 1) ][ #"?" ] ]

;-- append-into formatters : fill a reused buffer in place, no allocation
pad2-into: func [buf n][
    if n < 10 [ append buf #"0" ]
    append buf n
]
pad3-into: func [buf n][
    either n < 0 [ append buf "000" ][
        if n < 100 [ append buf #"0" ]
        if n < 10  [ append buf #"0" ]
        append buf n
    ]
]
fmt-time-into: func [buf ms /local s m][
    if ms < 0 [ ms: 0 ]
    s: to integer! (ms / 1000)
    m: to integer! (s / 60)
    s: s - (m * 60)
    pad2-into buf m
    append buf #":"
    pad2-into buf s
]

;-- precomputed string tables : every string the pattern grid can show, built
;-- once; the render loop only references them
note-strs: make block! 128
repeat n 127 [ append note-strs note-name n ]
note-str: func [n][
    case [
        n = 0    [ "..." ]
        n >= 128 [ "===" ]
        true     [ note-strs/(n) ]
    ]
]
hex-strs: make block! 256
repeat v 256 [ append hex-strs hex2 v - 1 ]
hex-str: func [v][ either all [ v >= 0  v < 256 ][ hex-strs/(v + 1) ][ hex-strs/1 ] ]
row-strs: make block! 256
repeat r 256 [ append row-strs pad2 r - 1 ]
row-str: func [r][ either all [ r >= 0  r < 256 ][ row-strs/(r + 1) ][ pad2 r ] ]
chw-strs: make block! 64
chn-strs: make block! 64
repeat c 64 [
    append chw-strs rejoin [ "CH" c ]
    append chn-strs form c
]
state-tags: [ idle "IDLE" playing "PLAYING" paused "PAUSED" draining "DRAINING" winddown "WINDDOWN" ]

;-- reused per-slot text buffers : each dynamic text cell needs its OWN series
;-- (the frame block holds references; clear + refill changes what it shows)
pos-buf:  make string! 12
pat-buf:  make string! 8
npat-buf: make string! 8
chn-buf:  make string! 8
inb-buf:  make string! 8
smp-buf:  make string! 8
bpm-buf:  make string! 8
spd-buf:  make string! 8
vol-buf:  make string! 8
el-buf:   make string! 8
rem-buf:  make string! 8
tot-buf:  make string! 8
;-- pattern-cell buffers, one per visible cell, grown on demand and reused
cell-pool: make block! 64
cell-buf: func [i][
    while [i > length? cell-pool][ append/only cell-pool make string! 12 ]
    clear cell-pool/(i)
]

;-- every emit-* helper APPENDS its draw code into `out` (compose/into writes
;-- straight into the frame block : no intermediate block is ever allocated)
;-- a raised beveled panel
emit-bevel: func [out org size face lt dk /local tr bl br][
    tr: org + (size * 1x0)
    bl: org + (size * 0x1)
    br: org + size
    compose/into [
        pen off fill-pen (face) box (org) (br)
        pen (lt) line (org) (tr) line (org) (bl)
        pen (dk) line (bl) (br) line (tr) (br)
    ] tail out
]
;-- a sunken near-black data box (dark edge top/left, light bottom/right)
emit-sunken: func [out org size /local tr bl br][
    tr: org + (size * 1x0)
    bl: org + (size * 0x1)
    br: org + size
    compose/into [
        pen off fill-pen (col-data-bg) box (org) (br)
        pen (col-bevel-dk) line (org) (tr) line (org) (bl)
        pen (col-bevel-lt) line (bl) (br) line (tr) (br)
    ] tail out
]
;-- a sunken strip of chrome (no dark fill) -> the FlodPro name rows + cells
emit-sunken-strip: func [out org size][
    emit-bevel out org size col-bg col-bevel-dk col-bevel-lt
]
;-- a sunken GRAY value cell with dark data text (FlodPro style)
emit-val-box: func [out org size txt][
    emit-sunken-strip out org size
    compose/into [
        pen (col-ink) font fnt-val text (as-pair (org/x + 6) (org/y + cen-y size/y th-val)) (txt)
    ] tail out
]
;-- same, text right-aligned inside the cell (times, volume %)
emit-val-box-r: func [out org size txt /local tx][
    tx: org/x + size/x - 7 - (to integer! (aw-val * length? txt))
    emit-sunken-strip out org size
    compose/into [
        pen (col-ink) font fnt-val text (as-pair tx (org/y + cen-y size/y th-val)) (txt)
    ] tail out
]
;-- a white label with a 1x1 dark drop shadow (font must be set by the caller)
emit-lbl-text: func [out pos txt][
    compose/into [
        pen (0.0.0.150)
        text (pos + 1x1) (txt)
        pen (col-white)
        text (pos) (txt)
    ] tail out
]
;-- a push-button : mode = 'up | 'dn (pressed / engaged) | 'dis (disabled)
;-- FlodPro look : gray face, fine bezel, WHITE label enabled / dark label disabled;
;-- pressed inverts the bezel, darkens the face and nudges the label +1x1
emit-btn: func [out org size lbl mode /local lx ly][
    either mode = 'dn [
        emit-bevel out org size col-face-dn col-bevel-dk col-bevel-lt
    ][
        emit-bevel out org size col-bg col-bevel-lt col-bevel-dk
    ]
    lx: to integer! ((size/x - (aw-btn * length? lbl)) / 2)
    ly: cen-y size/y th-btn
    if mode = 'dn [
        lx: lx + 1
        ly: ly + 1
    ]
    append out [ font fnt-btn ]
    either mode = 'dis [
        compose/into [
            pen (col-dim) text (org + (as-pair lx ly)) (lbl)
        ] tail out
    ][
        emit-lbl-text out (org + (as-pair lx ly)) lbl
    ]
]
;-- a push-button with a unicode transport icon (standard media symbols),
;-- centred from its measured glyph size, black enabled / dim disabled
icon-glyphs: [ "PLAY" "▶" "PAUSE" "❚❚" "STOP" "■" "LOOP" "↻" ]
icon-ink: copy []                ;-- glyph -> ink-top + ink-bottom (for true centring)
icon-szs: copy []                ;-- glyph -> measured size (the frame loop must not call size-text)

;-- symbol glyphs sit unpredictably inside their em box (the ↻ ink rides low),
;-- so render each one offscreen ONCE and record its real vertical ink bounds
measure-icon-inks: function [] [
    clear icon-ink
    clear icon-szs
    foreach [lbl gl] icon-glyphs [
        fname: either gl = "↻" [ 'fnt-icon-big ][ 'fnt-icon ]
        append icon-szs gl
        append icon-szs text-size get fname gl
        img: draw 48x48 compose [
            pen off
            fill-pen 255.255.255
            box 0x0 48x48
            anti-alias on
            pen 0.0.0
            font (fname)
            text 0x0 (gl)
        ]
        top: none
        bot: none
        repeat y 48 [
            inked?: no
            repeat x 48 [
                c: pick img as-pair x y
                if 600 > ((c/1 + c/2) + c/3) [ inked?: yes ]
            ]
            if inked? [
                if none? top [ top: y - 1 ]
                bot: y - 1
            ]
        ]
        if top [ append icon-ink reduce [ gl  top + bot ] ]
    ]
]
emit-btn-glyph: func [out org size gl mode /local icol sz lx ly fname oy][
    either mode = 'dn [
        emit-bevel out org size col-face-dn col-bevel-dk col-bevel-lt
    ][
        emit-bevel out org size col-bg col-bevel-lt col-bevel-dk
    ]
    icol: either mode = 'dis [ col-dim ][ col-ink ]
    fname: either gl = "↻" [ 'fnt-icon-big ][ 'fnt-icon ]
    sz: any [ select icon-szs gl  14x20 ]        ;-- measured once by measure-icon-inks
    lx: to integer! ((size/x - sz/x) / 2)
    ly: either oy: select icon-ink gl [
        to integer! ((size/y - oy) / 2)          ;-- centre the INK, not the em box
    ][
        to integer! ((size/y - sz/y) / 2)
    ]
    if mode = 'dn [
        lx: lx + 1
        ly: ly + 1
    ]
    compose/into [
        pen (icol) font (fname) text (org + (as-pair lx ly)) (gl)
    ] tail out
]

;-- a slider : sunken groove + raised square thumb at `frac` (0.0 .. 1.0)
emit-slider: func [out org size frac /local tx][
    if frac < 0.0 [ frac: 0.0 ]
    if frac > 1.0 [ frac: 1.0 ]
    tx: org/x + 1 + to integer! ((size/x - 12) * frac)
    emit-sunken out org size
    emit-bevel out (as-pair tx (org/y - 3)) (as-pair 10 (size/y + 6)) col-bg col-bevel-lt col-bevel-dk
]
;-- a spectrum bar, matched to the original : colour runs green->yellow->orange->
;-- red by ABSOLUTE height with a glossy gradient; the unlit part stays as a dim
;-- "ghost" of the same gradient (background bars); the peak cap is coloured by
;-- its own Y position.  `org`/`size` = the full bar cell, `litpx`/`pk` in px.
emit-grad-bar: func [out org size litpx pk /local br by ltop pky][
    br: org + size
    by: br/y
    ltop: by - litpx
    compose/into [
        pen off
        ;-- full-height colour gradient : green(low) -> yellow -> orange -> red(high)
        fill-pen linear (col-vu-green) 0.0 (col-vu-yellow) 0.5 (col-vu-orange) 0.76 (col-vu-red) 1.0 (as-pair org/x by) (org)
        box (org) (br)
        ;-- faint edge shading (NB Red tuple alpha = TRANSPARENCY : 0 opaque, 255 clear)
        fill-pen linear (0.0.0.195) 0.0 (0.0.0.255) 0.5 (0.0.0.185) 1.0 (org) (as-pair br/x org/y)
        box (org) (br)
        ;-- dim everything above the level -> a faint ghost of the bar behind
        fill-pen 0.0.0.52
        box (org) (as-pair br/x ltop)
    ] tail out
    ;-- peak cap, coloured by its own height (same gradient, full brightness)
    if pk > 2 [
        pky: by - pk
        compose/into [
            fill-pen linear (col-vu-green) 0.0 (col-vu-yellow) 0.5 (col-vu-orange) 0.76 (col-vu-red) 1.0 (as-pair org/x by) (org)
            box (as-pair org/x (pky - 2)) (as-pair br/x (pky + 1))
        ] tail out
    ]
]
;-- a VU meter, matched to the original trackers : the lit bar sits in a thin
;-- near-black recessed frame; its colour runs green->yellow->orange->red by
;-- ABSOLUTE height; and a glossy glass-tube bezel (bright highlight toward the
;-- left, shadow on the right) is painted ON the bar so it moves with the level.
;-- the lit bar ONLY — its black well is drawn in emit-chan-notes, UNDER the
;-- row highlight, so the highlight band runs unbroken across idle meters while
;-- an active bar crosses it brightly on top
emit-vu-bar: func [out org size litpx /local br by bx0 bx1 ltop lw rw][
    br:  org + size
    by:  br/y
    bx0: org/x + 2                 ;-- bar inset inside the thin black frame
    bx1: br/x - 2
    lw: to integer! ((bx1 - bx0) * 2 / 10)       ;-- light band : left fifth
    if lw < 2 [ lw: 2 ]
    rw: to integer! ((bx1 - bx0) * 15 / 100)     ;-- dark band : right ~sixth
    if rw < 2 [ rw: 2 ]
    if litpx > 1 [
        ltop: by - litpx
        compose/into [
            pen off
            ;-- level colour by absolute height : green(low) -> yellow -> orange -> red(high)
            fill-pen linear (col-vu-green) 0.0 (col-vu-yellow) 0.5 (col-vu-orange) 0.76 (col-vu-red) 1.0 (as-pair bx0 by) (as-pair bx0 org/y)
            box (as-pair bx0 ltop) (as-pair bx1 by)
            ;-- bezel as FLAT hard-edged bands, like the palette-drawn originals :
            ;-- lighter strip on the left, darker strip on the right
            ;-- (NB Red tuple alpha = TRANSPARENCY : 0 opaque, 255 clear)
            fill-pen 255.255.255.165
            box (as-pair bx0 ltop) (as-pair (bx0 + lw) by)
            fill-pen 0.0.0.150
            box (as-pair (bx1 - rw) ltop) (as-pair bx1 by)
        ] tail out
    ]
]

;-- static chrome (panels, frames, static labels, logo, wordmark) -------------
build-chrome: function [] [
    out: make block! 400
    compose/into [ pen off fill-pen (col-bg) box 0x0 (win-size) ] tail out
    ;-- header + wordmark (the 🎵/🎶 flourishes replace the old cherry bitmap)
    emit-bevel out hd-org hd-size col-bg col-bevel-lt col-bevel-dk
    ;-- (the wordmark is drawn by build-wordmark, appended LAST in render :
    ;--  this Draw build has no shadow reset, so the shadow must trail the frame)
    ;-- param panel + row labels, centered on their value cells (cells at ry-2, 20 high)
    emit-bevel out pp-org pp-size col-bg col-bevel-lt col-bevel-dk
    append out [ font fnt-lbl ]
    ry: pp-org/y + 10
    foreach lbl ["Position" "Pattern" "Patterns" "Channels" "Instruments" "Samples" "Tempo" "Speed" "Volume"][
        emit-lbl-text out (as-pair (pp-org/x + 12) (ry - 2 + cen-y 20 th-lbl)) lbl
        ry: ry + 24
    ]
    ;-- spectrum panel (frame + a sunken well sized exactly to the bar field;
    ;-- the analyzer itself is FINAL)
    emit-bevel out sp-org sp-size col-bg col-bevel-lt col-bevel-dk
    emit-sunken out (spec-well - 2x2) (as-pair (spec-used + 4) (spec-fh + 4))
    ;-- the 3 name rows : sunken strips + WHITE right-aligned labels
    emit-sunken-strip out (nm-org + 0x0)  (as-pair nm-size/x 26)
    emit-sunken-strip out (nm-org + 0x28) (as-pair nm-size/x 26)
    emit-sunken-strip out (nm-org + 0x56) (as-pair nm-size/x 26)
    lbx: nm-org/x + 100
    lby: cen-y 26 th-lbl
    append out [ font fnt-lbl ]
    emit-lbl-text out (as-pair (lbx - to integer! (aw-lbl * 5)) (nm-org/y + lby))      "Song:"
    emit-lbl-text out (as-pair (lbx - to integer! (aw-lbl * 5)) (nm-org/y + 28 + lby)) "File:"
    emit-lbl-text out (as-pair (lbx - to integer! (aw-lbl * 8)) (nm-org/y + 56 + lby)) "Tracker:"
    ;-- channels panel
    emit-bevel out ch-org ch-size col-bg col-bevel-lt col-bevel-dk
    emit-sunken out (ch-org + 6x6) (ch-size - 12x12)
    out
]

;-- the real vertical ink bounds [top bottom] (0-based) of `str` in font `fword`
;-- (a WORD! — Draw needs fonts by word), rendered offscreen & pixel-scanned.
;-- lets us align glyphs from DIFFERENT fonts (the Segoe notes vs the Consolas
;-- wordmark) by their ink centre.  First-tick only — never in the frame path.
ink-bounds: function [fword str /local img top bot c inked?][
    img: draw 240x90 compose [
        pen off fill-pen 255.255.255 box 0x0 240x90
        anti-alias on pen 0.0.0 font (fword) text 0x0 (str)
    ]
    top: none  bot: none
    repeat y 90 [
        inked?: no
        repeat x 240 [
            c: pick img as-pair x y
            if 600 > ((c/1 + c/2) + c/3) [ inked?: yes ]
        ]
        if inked? [ if none? top [ top: y - 1 ]  bot: y - 1 ]
    ]
    either top [ reduce [ top bot ] ][ reduce [ 0 0 ] ]
]

;-- the wordmark : 🎶 + "Cherry" (cherry-red) and "Tracker" (stem-green, no tail note),
;-- each glyph vertically shaded by a gradient pen (gradient pens fill text AND
;-- the monochrome Segoe notes).  Drop shadow EMULATED by an offset translucent
;-- dark pass underneath — Draw `shadow` parses but renders NOTHING here (GDI+),
;-- verified offscreen.  Built once at first tick (advances + note inks measured).
build-wordmark: function [] [
    out: make block! 64
    ;-- exact advances via the measurement-DIFFERENCE trick (constant padding cancels)
    cadv: (text-size fnt-logo "CherryCherry") - (text-size fnt-logo "Cherry")
    nadv: (text-size fnt-note "🎶🎶")         - (text-size fnt-note "🎶")   ;-- leading 🎶 advance
    gap: 8
    ex:  hd-org/x + 14                          ;-- leading 🎶 where the cherry bitmap sat
    cx:  ex + nadv/x + gap                       ;-- "Cherry" after the note
    tx:  cx + cadv/x                             ;-- "Tracker" abuts "Cherry" like one word
    ly:  hd-org/y + cen-y hd-size/y th-logo
    gy0: ly + 6
    gy1: ly + th-logo - 6
    ;-- centre the note's own ink on the wordmark cap band (Segoe vs Consolas metrics)
    li:  ink-bounds 'fnt-logo "C"
    lc:  to integer! ((li/1 + li/2) / 2)         ;-- wordmark cap ink centre
    nb:  ink-bounds 'fnt-note "🎶"               ;-- leading 🎶 ink
    bey: ly + lc - (to integer! ((nb/1 + nb/2) / 2))
    compose/into [
        ;-- shadow pass (1px offset, translucent dark) for every glyph
        font fnt-note
        pen (0.0.0.150)
        text (as-pair (ex + 1) (bey + 1)) "🎶"
        font fnt-logo
        text (as-pair (cx + 1) (ly + 1)) "Cherry"
        text (as-pair (tx + 1) (ly + 1)) "Tracker"
        ;-- 🎶 + Cherry : cherry-red vertical gradient
        font fnt-note
        pen linear (col-cherry-t) 0.0 (col-cherry-b) 1.0 (as-pair ex (bey + nb/1)) (as-pair ex (bey + nb/2))
        text (as-pair ex bey) "🎶"
        font fnt-logo
        pen linear (col-cherry-t) 0.0 (col-cherry-b) 1.0 (as-pair cx gy0) (as-pair cx gy1)
        text (as-pair cx ly) "Cherry"
        ;-- Tracker : stem-green vertical gradient (no trailing note)
        pen linear (col-stem-t) 0.0 (col-stem-b) 1.0 (as-pair tx gy0) (as-pair tx gy1)
        text (as-pair tx ly) "Tracker"
    ] tail out
    out
]

;-- dynamic: param value boxes + position spinners + volume slider
emit-params: function [out][
    vbx: pp-org/x + 124
    ry:  pp-org/y + 10
    ;-- Position row : spinners + pos/len
    emit-btn out spin-l-org spin-size "<" case [
        spin-press = 'l [ 'dn ]
        loaded?         [ 'up ]
        true            [ 'dis ]
    ]
    emit-btn out spin-r-org spin-size ">" case [
        spin-press = 'r [ 'dn ]
        loaded?         [ 'up ]
        true            [ 'dis ]
    ]
    clear pos-buf
    pad3-into pos-buf pt-pos
    append pos-buf " / "
    pad3-into pos-buf pt-len
    emit-val-box out (as-pair (pp-org/x + 168) (ry - 2)) 166x20 pos-buf
    ry: ry + 24
    clear pat-buf
    pad3-into pat-buf pt-pattern
    emit-val-box out (as-pair vbx (ry - 2)) 210x20 pat-buf
    ry: ry + 24
    clear npat-buf
    pad3-into npat-buf pt-npat
    emit-val-box out (as-pair vbx (ry - 2)) 210x20 npat-buf
    ry: ry + 24
    clear chn-buf
    pad2-into chn-buf pt-channels
    emit-val-box out (as-pair vbx (ry - 2)) 210x20 chn-buf
    ry: ry + 24
    clear inb-buf
    pad2-into inb-buf pt-ins
    emit-val-box out (as-pair vbx (ry - 2)) 210x20 inb-buf
    ry: ry + 24
    clear smp-buf
    pad2-into smp-buf pt-smp
    emit-val-box out (as-pair vbx (ry - 2)) 210x20 smp-buf
    ry: ry + 24
    clear bpm-buf
    pad3-into bpm-buf pt-bpm
    emit-val-box out (as-pair vbx (ry - 2)) 210x20 bpm-buf
    ry: ry + 24
    clear spd-buf
    pad2-into spd-buf pt-speed
    emit-val-box out (as-pair vbx (ry - 2)) 210x20 spd-buf
    ;-- Volume row : slider + value cell
    emit-slider out vol-org vol-size (volume / 100.0)
    clear vol-buf
    append vol-buf volume
    emit-val-box-r out (as-pair (vol-org/x + vol-size/x + 8) (vol-org/y - 4)) 44x20 vol-buf
]

;-- dynamic: transport buttons (mode reflects state, press + disabled)
;-- indexed walk over `btns` : a per-frame foreach would allocate its context
emit-buttons: function [out][
    i: 1
    while [i < length? btns][
        lbl:  btns/(i)
        borg: btns/(i + 1)
        mode: case [
            find btn-reserved lbl [ 'dis ]
            btn-pressed = lbl [ 'dn ]
            all [ lbl = "PLAY"  state = 'playing ] [ 'dn ]
            all [ lbl = "PAUSE" state = 'paused  ] [ 'dn ]
            all [ lbl = "LOOP"  loop? ]            [ 'dn ]
            lbl = "LOAD" [ 'up ]
            lbl = "LOOP" [ 'up ]
            loaded?      [ 'up ]
            true         [ 'dis ]
        ]
        either gl: select icon-glyphs lbl [
            emit-btn-glyph out borg btn-size gl mode
        ][
            emit-btn out borg btn-size lbl mode
        ]
        i: i + 2
    ]
]

;-- dynamic: spectrum-analyzer bars (envelope from the synced scope buffer)
emit-spectrum: function [out][
    iorg: spec-well
    bw:   spec-bw
    barw: bw - 2
    if barw < 2 [ barw: 2 ]
    b: 0
    while [b < SPEC-NB][
        m: pt-band b                               ;-- band magnitude^2 (float)
        level: SPEC-LO
        if m > 1e-6 [
            level: (log-10 m) + ((SPEC-TILT * b) / (SPEC-NB - 1))
            if level < SPEC-LO [ level: SPEC-LO ]
        ]
        frac: (level - SPEC-LO) / (SPEC-HI - SPEC-LO)
        if frac < 0.0 [ frac: 0.0 ]
        if frac > 1.0 [ frac: 1.0 ]
        target: to integer! (frac * spec-fh)
        ;-- bar : fast attack, fast decay — the bars pump much quicker than the caps
        lvl: spec-level/(b + 1)
        either target > lvl [
            step: to integer! ((target - lvl) * 55 / 100)
            if step < 1 [ step: 1 ]
            lvl: lvl + step
            if lvl > target [ lvl: target ]
        ][
            step: to integer! ((lvl - target) * 13 / 100)
            if step < 1 [ step: 1 ]
            lvl: lvl - step
            if lvl < target [ lvl: target ]
        ]
        spec-level/(b + 1): lvl
        ;-- peak cap : jumps to a new peak, HOLDS there for a moment, then
        ;-- resumes the same slow fall — classic peak-hold ballistics (the hold
        ;-- is the lag; the fall rate is unchanged)
        pk: spec-peak/(b + 1)
        either lvl >= pk [
            pk: lvl                                       ;-- new peak : pin it +
            spec-phold/(b + 1): SPEC-CAP-HOLD             ;-- arm the hold
        ][
            either spec-phold/(b + 1) > 0 [
                spec-phold/(b + 1): (spec-phold/(b + 1)) - 1   ;-- holding : stay put
            ][
                pk: pk - 3                                ;-- hold expired : fall (3 px/frame)
            ]
        ]
        if pk < 0 [ pk: 0 ]
        spec-peak/(b + 1): pk
        emit-grad-bar out (iorg + (as-pair (b * bw) 0)) (as-pair barw spec-fh) lvl pk
        b: b + 1
    ]
]

;-- dynamic: name-row values, seek slider, elapsed / remaining / total times
;-- (name-cache / file-line / type-cache are prepared by load-file, truncation
;-- included — the frame loop only references them)
emit-names: function [out][
    tot: pt-duration
    el: either find [playing paused draining] state [ pt-time-ms ][ 0 ]
    if el > tot [ el: tot ]
    ;-- values (dark data text on the gray strips, centered on the 26-high rows)
    vy: cen-y 26 th-val
    compose/into [ pen (col-ink) font fnt-val
        text (as-pair (nm-org/x + 108) (nm-org/y + vy))      (name-cache)
        text (as-pair (nm-org/x + 108) (nm-org/y + 28 + vy)) (file-line)
        text (as-pair (nm-org/x + 108) (nm-org/y + 56 + vy)) (type-cache)
    ] tail out
    ;-- seek slider (Song row) + time cells : elapsed / -remaining / total.
    ;-- quantize to whole seconds ONCE and derive both from it, so the two
    ;-- cells flip in the same frame (raw tot-el flips at a phase offset of
    ;-- tot//1000 -> the cells looked ~0.5s out of step)
    frac: either tot > 0 [ (1.0 * el) / tot ][ 0.0 ]
    emit-slider out seek-org seek-size frac
    els:  to integer! (el / 1000)
    tots: to integer! (tot / 1000)
    clear el-buf
    fmt-time-into el-buf (1000 * els)
    emit-val-box-r out (as-pair tb-x (nm-org/y + 3))  (as-pair tb-w 20) el-buf
    clear rem-buf
    append rem-buf #"-"
    fmt-time-into rem-buf (1000 * (tots - els))
    emit-val-box-r out (as-pair tb-x (nm-org/y + 31)) (as-pair tb-w 20) rem-buf
    clear tot-buf
    fmt-time-into tot-buf (1000 * tots)
    emit-val-box-r out (as-pair tb-x (nm-org/y + 59)) (as-pair tb-w 20) tot-buf
    ;-- header state tag, right-aligned + centered
    stag: select state-tags state
    append out [ font fnt-lbl ]
    emit-lbl-text out (as-pair (hd-org/x + hd-size/x - 14 - to integer! (aw-lbl * length? stag)) (hd-org/y + cen-y hd-size/y th-lbl)) stag
]

;-- per-channel note columns + row gutter + dividers + CH labels
;-- (cached on view-pat/view-row/nch change; view-* may be virtual during
;-- winddown.  every string comes from the precomputed tables or the reused
;-- cell-pool buffers — a rebuild allocates nothing)
emit-chan-notes: function [out][
    nch: pt-channels
    if nch <= 0 [ nch: 4 ]
    cpat:  view-pat
    crow:  view-row
    nrows: view-nrows
    cc-x: ch-org/x + 44                          ;-- columns inside the inset, after the row gutter
    cc-w: ch-size/x - 54
    colw: to integer! (cc-w / nch)
    vuw: to integer! (colw * 3 / 10)             ;-- match emit-chan-vu
    if vuw > 38 [ vuw: 38 ]
    if vuw < 12 [ vuw: 12 ]
    if vuw > (colw - 8) [ vuw: colw - 8 ]        ;-- ultra-narrow columns (32+ channels)
    if vuw < 4 [ vuw: 4 ]
    notex: vuw + 9                               ;-- note text clears the (wider) VU bar
    showtext?:  colw >= (notex + 76)
    shownotes?: colw >= 46                       ;-- below this, meters only
    rh: 20                                       ;-- >= line height so rows never overlap
    visible: to integer! ((ch-size/y - 40) / rh)
    if visible < 3 [ visible: 3 ]
    if even? visible [ visible: visible - 1 ]
    half: to integer! ((visible - 1) / 2)
    ;-- VU wells first : they must sit UNDER the row highlight (see emit-vu-bar)
    vuh:   ch-size/y - 40
    vutop: ch-org/y + 30
    c: 0
    while [c < nch][
        cx: cc-x + (c * colw) + 4
        compose/into [ pen off fill-pen (col-vu-well) box (as-pair cx vutop) (as-pair (cx + vuw) (vutop + vuh)) ] tail out
        c: c + 1
    ]
    ;-- dividers + CH labels (narrow columns : bare number, centred, so the
    ;-- label never crosses the divider or the panel edge)
    c: 0
    while [c < nch][
        cx: cc-x + (c * colw)
        if c > 0 [ compose/into [ pen (col-data-edge) line (as-pair cx (ch-org/y + 8)) (as-pair cx (ch-org/y + ch-size/y - 8)) ] tail out ]
        either colw >= 70 [
            lbl:   chw-strs/(c + 1)
            lx:    cx + notex
            fname: 'fnt-lbl
        ][
            lbl: chn-strs/(c + 1)
            ;-- shrink the font once a 2-digit number no longer clears the column
            either (2 * aw-lbl) + 6 > colw [
                fname: 'fnt-chan
                aw:    aw-chan
            ][
                fname: 'fnt-lbl
                aw:    aw-lbl
            ]
            lx: cx + to integer! ((colw - (aw * length? lbl)) / 2)
        ]
        compose/into [ pen (col-white) font (fname) text (as-pair lx (ch-org/y + 8)) (lbl) ] tail out
        c: c + 1
    ]
    if all [ nrows > 0  cpat >= 0 ][
        slot: 0
        i: negate half
        while [i <= half][
            rr: crow + i
            cy: (ch-org/y + 28) + ((i + half) * rh)
            if all [ rr >= 0  rr < nrows ][
                ;-- highlight band nudged +2px : the fnt-pat line box leads high, so
                ;-- its ink rides low in the box — measured 6px gap above / 2px below,
                ;-- this re-centres the text ink top-to-bottom in the band
                if i = 0 [ compose/into [ pen off fill-pen (col-row-hi-bg) box (as-pair (ch-org/x + 8) (cy + 1)) (as-pair (ch-org/x + ch-size/x - 8) (cy + rh + 1)) ] tail out ]
                txcol: either i = 0 [ col-row-hi-tx ][ col-note ]
                ;-- row number in the left gutter
                compose/into [ pen (txcol) font fnt-pat text (as-pair (ch-org/x + 14) cy) (row-str rr) ] tail out
                if shownotes? [
                    c: 0
                    while [c < nch][
                        cx: cc-x + (c * colw) + notex
                        nt: pt-cell cpat c rr 0
                        cell: either showtext? [
                            slot: slot + 1
                            buf: cell-buf slot
                            append buf note-str nt
                            append buf #" "
                            ins: pt-cell cpat c rr 1
                            either ins = 0 [ append buf ".." ][ append buf hex-str ins ]
                            append buf #" "
                            append buf fx-type pt-cell cpat c rr 3
                            append buf hex-str pt-cell cpat c rr 4
                            buf
                        ][ note-str nt ]
                        compose/into [ pen (txcol) font fnt-pat text (as-pair cx cy) (cell) ] tail out
                        c: c + 1
                    ]
                ]
            ]
            i: i + 1
        ]
    ]
]

;-- per-channel VU meters (one bar at the left of each channel column)
emit-chan-vu: function [out][
    nch: pt-channels
    if nch <= 0 [ nch: 4 ]
    vb: pt-volbase
    if vb <= 0 [ vb: 64 ]
    cc-x: ch-org/x + 44                          ;-- keep in sync with emit-chan-notes
    cc-w: ch-size/x - 54
    colw: to integer! (cc-w / nch)
    vuw: to integer! (colw * 3 / 10)
    if vuw > 38 [ vuw: 38 ]
    if vuw < 12 [ vuw: 12 ]
    if vuw > (colw - 8) [ vuw: colw - 8 ]
    if vuw < 4 [ vuw: 4 ]
    vuh:   ch-size/y - 40
    vutop: ch-org/y + 30
    c: 0
    while [c < nch][
        cx: cc-x + (c * colw) + 4
        v: pt-cvol c
        target: to integer! (v * vuh / vb)
        if target > vuh [ target: vuh ]
        ;-- ease the displayed level toward the target : fast attack, slow decay
        lvl: vu-level/(c + 1)
        either target > lvl [
            step: to integer! ((target - lvl) * VU-ATTACK / 100)
            if step < 1 [ step: 1 ]
            lvl: lvl + step
            if lvl > target [ lvl: target ]
        ][
            step: to integer! ((lvl - target) * VU-DECAY / 100)
            if step < 1 [ step: 1 ]
            lvl: lvl - step
            if lvl < target [ lvl: target ]
        ]
        vu-level/(c + 1): lvl
        emit-vu-bar out (as-pair cx vutop) (as-pair vuw vuh) lvl
        c: c + 1
    ]
]

;-- assemble all layers into the ONE persistent frame block (it IS canvas/draw,
;-- installed once at startup).  clear keeps the allocated capacity and every
;-- emitted value is an immediate or a reused series reference, so after
;-- warm-up a frame allocates NOTHING and the GC stays idle (Rednoid pattern).
render: does [
    clear frame-tail                        ;-- keep the anti-alias/scale prefix
    append frame-blk chrome-block
    emit-params   frame-blk
    emit-spectrum frame-blk
    emit-buttons  frame-blk
    emit-names    frame-blk
    n: pt-channels
    if any [ view-pat <> last-pat  view-row <> last-row  n <> last-nch ][
        clear chan-blk
        emit-chan-notes chan-blk
        last-pat: view-pat
        last-row: view-row
        last-nch: n
    ]
    append frame-blk chan-blk
    emit-chan-vu frame-blk
    append frame-blk wordmark-block         ;-- LAST : its shadow must not leak
]

;-- state transitions ----------------------------------------------------------
;-- rewind + silence + zero the visual sources; bars then EASE down and the
;-- rows scroll out of view (see tick) before the player goes idle
enter-winddown: does [
    pt-restart
    pt-clear-state
    wind-row:  view-row
    wind-tick: 0
    state: 'winddown
]

do-action: func [lbl][
    switch lbl [
        "PLAY" [
            if all [ loaded?  state <> 'playing ][
                if state = 'paused [ pt-resume-dev ]
                state: 'playing
            ]
        ]
        "PAUSE" [
            switch state [
                playing [
                    pt-pause-dev
                    state: 'paused
                ]
                paused [
                    pt-resume-dev
                    state: 'playing
                ]
            ]
        ]
        "STOP" [
            if all [ loaded?  not find [idle winddown] state ][
                if state = 'paused [ pt-resume-dev ]
                enter-winddown
            ]
        ]
        "PREV" [
            if loaded? [
                if state = 'paused [ pt-resume-dev ]
                pt-prev
                state: 'playing
            ]
        ]
        "NEXT" [
            if loaded? [
                if state = 'paused [ pt-resume-dev ]
                pt-next
                state: 'playing
            ]
        ]
        "LOOP" [
            loop?: not loop?
            pt-set-loop either loop? [1][0]
        ]
        "LOAD" [ load-mod ]
    ]
]

apply-volume: does [ pt-set-gain (volume / 100.0) ]
set-vol-from-x: func [dx [integer!] /local v][
    v: to integer! ((dx - vol-org/x) * 100 / vol-size/x)
    if v < 0 [ v: 0 ]
    if v > 100 [ v: 100 ]
    volume: v
    apply-volume
]
;-- seek to the time under design-x `dx` (throttled while dragging)
do-seek-x: func [dx [integer!] /local tot frac ms][
    tot: pt-duration
    if any [ not loaded?  tot <= 0 ][ exit ]
    frac: (1.0 * (dx - seek-org/x)) / seek-size/x
    if frac < 0.0 [ frac: 0.0 ]
    if frac > 1.0 [ frac: 1.0 ]
    ms: to integer! (frac * tot)
    if 1200 < absolute (ms - last-seek-ms) [
        last-seek-ms: ms
        if state = 'paused [ pt-resume-dev ]
        pt-seek ms
        state: 'playing
    ]
]

;-- pointer events arrive in logical face coords; map back to 1024x768 design
;-- map a logical face offset back to 1024x768 design space — the inverse of the
;-- letterbox transform : subtract the centring offset, divide by the fit scale
to-design: func [off][
    as-pair
        to integer! ((off/x - fit-ofs/x) / fit-s)
        to integer! ((off/y - fit-ofs/y) / fit-s)
]
pt-on-down: func [off /local pos][
    pos: to-design off
    btn-pressed: none
    case [
        within? pos (vol-org - 6x8) (vol-size + 12x16) [
            vol-drag?: yes
            set-vol-from-x pos/x
        ]
        within? pos (seek-org - 6x8) (seek-size + 12x16) [
            seek-drag?: yes
            last-seek-ms: -999999
            do-seek-x pos/x
        ]
        within? pos spin-l-org spin-size [
            spin-press: 'l
            do-action "PREV"
        ]
        within? pos spin-r-org spin-size [
            spin-press: 'r
            do-action "NEXT"
        ]
        true [
            foreach [lbl borg] btns [
                if all [ within? pos borg btn-size  not find btn-reserved lbl ][
                    btn-pressed: lbl                 ;-- visual press; action fires on release
                    break
                ]
            ]
        ]
    ]
]
pt-on-up: func [off /local pos][
    pos: to-design off
    if btn-pressed [
        foreach [lbl borg] btns [
            if all [ lbl = btn-pressed  within? pos borg btn-size ][
                do-action lbl
                break
            ]
        ]
    ]
    btn-pressed: none
    spin-press:  none
    vol-drag?:   no
    seek-drag?:  no
]
pt-on-over: func [off /local d][
    d: to-design off
    if vol-drag?  [ set-vol-from-x d/x ]
    if seek-drag? [ do-seek-x d/x ]
]

load-file: func [f [file!] /local data res][
    data: attempt [ read/binary f ]
    either none? data [
        name-cache: "<file not found>"
        loaded?: no
        state: 'idle
    ][
        res: pt-load-mem data
        either zero? res [
            name-cache: pt-songname
            type-cache: pt-modtype
            file-cache: form second split-path f
            size-cache: rejoin [ "(" to integer! (((length? data) + 512) / 1024) " KB)" ]
            if empty? trim copy name-cache [ name-cache: copy file-cache ]
            ;-- the name rows show these as-is every frame : truncate + join NOW
            if 40 < length? name-cache [ name-cache: copy/part name-cache 40 ]
            if 34 < length? type-cache [ type-cache: copy/part type-cache 34 ]
            file-line: rejoin [ file-cache "  " size-cache ]
            loaded?: yes
            if state = 'paused [ pt-resume-dev ]
            state: 'playing
            view-pat: -1
            view-row: 0
            view-nrows: 0
            last-pat: -2
            last-seek-ms: 0
            vu-level: append/dup make block! 64 0 64
            apply-volume
        ][
            name-cache: rejoin ["<load error " res ">"]
            loaded?: no
            state: 'idle
        ]
    ]
]
load-mod: does [
    f: request-file/title "Load module"
    if none? f [ exit ]
    if block? f [ f: first f ]
    load-file f
]

;-- one animation frame : first-tick lazy init, drive the state machine, sync the
;-- visible row/pattern, repaint.  Split out from `tick` so the timer guard stays
;-- a tiny NON-throwing wrapper (see `tick`).  Contains no exit/return/throw.
tick-frame: does [
    ;-- first tick : measure the real font metrics, then build the chrome with them
    if empty? chrome-block [
        measure-fonts
        measure-icon-inks
        chrome-block: build-chrome
        wordmark-block: build-wordmark
    ]
    switch state [
        playing [
            if 1 = pt-pump [ state: 'draining ]     ;-- decoded to the end : let the queue play out
            pt-sync
        ]
        draining [
            pt-sync
            if 1 > pt-queued [ enter-winddown ]     ;-- tail played : ease everything down
        ]
        winddown [
            wind-tick: wind-tick + 1
            if wind-tick >= 2 [
                wind-tick: 0
                wind-row: wind-row + 1              ;-- rows scroll up and out of view
            ]
            if wind-row > (view-nrows + 9) [ state: 'idle ]
        ]
    ]
    case [
        find [playing draining] state [
            view-pat:   pt-pattern
            view-row:   pt-row
            view-nrows: pt-numrows
        ]
        state = 'winddown [ view-row: wind-row ]
        true []
    ]
    render
]

;-- called DIRECTLY from the manual render loop (NOT a `rate` timer — see the loop
;-- and the close-race analysis near the end of the file).  The guard keeps tick
;-- inert and NON-throwing if it is ever reached while the window is closing or its
;-- face has been torn down (`canvas/state` is none then) — cheap belt-and-braces on
;-- top of the loop's own `win/state` exit condition.
tick: does [
    if all [ not closing?  canvas/state ][ tick-frame ]
]

;-- precompute the Goertzel coefficients (2*cos w) + the Hann window in Red,
;-- push them to R/S (no trig needed on the R/S side)
fill-spec-coeffs: does [
    lr: log-e (SPEC-FMAX / SPEC-FMIN)
    i: 0
    while [i < SPEC-NB][
        frac: either SPEC-NB > 1 [ (i * 1.0) / (SPEC-NB - 1) ][ 0.0 ]
        f: SPEC-FMIN * (exp (frac * lr))
        pt-set-coeff i (2.0 * cosine ((360.0 * f) / 44100.0))
        i: i + 1
    ]
    i: 0
    while [i < SPEC-SAMPLES][
        pt-set-win i (0.5 - (0.5 * cosine ((360.0 * i) / (SPEC-SAMPLES - 1))))
        i: i + 1
    ]
]

chrome-block:   copy []         ;-- built on the first tick, after measure-fonts
wordmark-block: copy []
;-- the persistent frame block (the zero-allocation loop's single buffer) and
;-- the cached channel layer, rebuilt only when the visible row/pattern moves
frame-blk: make block! 6000
chan-blk:  make block! 1600
frame-tail: none                ;-- set right after the scale prefix, below

;-- Red/View is per-monitor-DPI-aware (manifest) -> face coords are LOGICAL.
;-- Size the canvas = physical(1024x768) / desktop-scale; draw through `scale`.
dpi: 1.0
attempt [
    raw: system/view/screens/1/data
    if number? raw [ dpi: either raw > 8.0 [ raw / 100.0 ][ 1.0 * raw ] ]
]
if dpi <= 0.0 [ dpi: 1.0 ]
draw-scale: 1.0 / dpi
face-size: as-pair (to integer! (win-size/x * draw-scale)) (to integer! (win-size/y * draw-scale))

;-- LETTERBOX FIT : the 1024x768 design is scaled to the LARGEST size that fits
;-- the canvas while preserving its 4:3 aspect, then centred; the margins are
;-- filled with chrome gray (so a non-4:3 / maximized window reads as the UI
;-- centred in gray, not black bars).  Recomputed on every resize / maximize.
fit-s:   draw-scale             ;-- design -> device scale
fit-ofs: 0x0                    ;-- device-space centring offset (pair!)
recompute-fit: func [sz [pair!]][
    fit-s: min (1.0 * sz/x / win-size/x) (1.0 * sz/y / win-size/y)
    fit-ofs: as-pair
        to integer! ((sz/x - (win-size/x * fit-s)) / 2)
        to integer! ((sz/y - (win-size/y * fit-s)) / 2)
]
;-- (re)build the PERMANENT Draw prefix for canvas size `sz` : a full-canvas gray
;-- fill (the letterbox margins, in device space) then translate+scale for the
;-- design.  frame-tail is left right after it, so render only refills the design
;-- layers past it (the zero-allocation loop is unchanged; resize is infrequent).
rebuild-prefix: func [sz [pair!]][
    recompute-fit sz
    clear frame-blk
    append frame-blk reduce [
        'anti-alias 'on
        'pen 'off 'fill-pen col-bg 'box 0x0 sz
        'translate fit-ofs 'scale fit-s fit-s
    ]
    frame-tail: tail frame-blk
]
rebuild-prefix face-size

init-rc: pt-init
unless zero? init-rc [ print ["*** pt-init failed, code=" init-rc] ]
if zero? init-rc [ fill-spec-coeffs ]
cli: system/options/args
if all [ zero? init-rc  block? cli  not empty? cli ][ load-file to-red-file first cli ]

win: layout compose [
    title "CherryTracker"
    origin 0x0
    canvas: base (face-size) all-over draw []
        on-time [ tick ]                ;-- actor wired, but rate stays NONE except
        on-down [ pt-on-down event/offset ]   ;-- transiently during a move/resize drag
        on-over [ pt-on-over event/offset ]
        on-up   [ pt-on-up event/offset ]
]
;-- re-letterbox to a new client size `sz` (non-throwing guard, same as tick)
relayout: func [sz [pair!]][
    if all [ not closing?  canvas/state ][
        canvas/size: sz
        rebuild-prefix sz
        render
    ]
]
;-- KEEP PLAYING + ANIMATING WHILE MOVING/RESIZING.  Those OS modal loops block the
;-- manual render loop (below), but they DO pump WM_TIMER — so arm a transient
;-- `rate` timer for the duration of the drag and `tick` keeps firing through it
;-- (audio pump + animation).  The manual loop disarms it the instant it regains
;-- control.  Only the size/move modal loops fire on-resizing/on-moving and arm it;
;-- the ✕-button modal loop fires NEITHER, so the close path stays timer-free and
;-- the Error 95 race cannot come back.
arm-modal-timer: does [ unless timer-on? [ canvas/rate: 60  timer-on?: yes ] ]

win/flags: [resize]             ;-- WS_THICKFRAME + keeps the maximize box (gui.reds OS-make-view)
win/actors: make object! [
    ;-- on close : latch `closing?`, defensively kill any timer (normally already
    ;-- off — a drag can't overlap a close), silence the device; the loop then exits
    on-close: func [face event][
        closing?: yes
        canvas/rate: none
        pt-pause-dev
    ]
    ;-- DURING a drag : arm the timer + follow the new size live.  EVT_SIZE is
    ;-- SUPPRESSED while win-state=1 (events.reds:1675), so `on-resize` alone won't
    ;-- relayout mid-drag — `on-resizing` must.
    on-resizing: func [face event][ arm-modal-timer  relayout face/size ]
    on-moving:   func [face event][ arm-modal-timer ]
    ;-- final commit (WM_EXITSIZEMOVE) + maximize / programmatic resize
    on-resize:   func [face event][ relayout face/size ]
]
;-- install the persistent frame block ONCE; every later frame only mutates it
;-- (ownership events from the mutations keep the canvas repainting)
canvas/draw: frame-blk

;-- MANUAL render loop instead of a permanent `rate`/`on-time` timer.  A timer
;-- dispatches `tick` as an EVENT; the ✕-button's modal loop keeps pumping those
;-- timer events while the window tears down, and that interleaving occasionally
;-- corrupts Red's per-event try-frame state -> an escaped THROW = "Runtime Error
;-- 95: no CATCH for THROW" (rare on Windows, more frequent on GTK).  Driving `tick`
;-- DIRECTLY here, with the close handled by `do-events`, keeps the timer OFF on the
;-- close path.  The ONLY time a timer runs is transiently during a move/resize drag
;-- (armed by on-resizing/on-moving above — that modal loop blocks this one but
;-- pumps WM_TIMER, so animation/audio continue); we disarm it the instant we regain
;-- control.  `win/state` becomes none when the close removes the face, ending the
;-- loop.  `wait` paces ~60fps at low CPU (same granularity ceiling `rate` hit).
view/no-wait win
while [win/state][
    if timer-on? [ canvas/rate: none  timer-on?: no ]   ;-- reclaim rendering from the drag timer
    tick
    do-events/no-wait
    if win/state [ wait 0:0:0.01 ]
]

pt-quit
