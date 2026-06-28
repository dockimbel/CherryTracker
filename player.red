Red [
	Title:   "CherryTracker — module player"
	Author:  "Nenad Rakocevic"
	Version: 1.0.0
	Needs:   'View
	Icon:    %assets/cherry.ico
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
	pt-spec-coeff: as float-ptr! 0       ;-- PT-NB filter coeffs (2*cos w), from Red
	pt-spec-mag:   as float-ptr! 0       ;-- PT-NB current band magnitudes (squared)
	pt-fft-buf:    as float-ptr! 0       ;-- PT-FFT-N mono scratch samples
	pt-spec-win:   as float-ptr! 0       ;-- PT-FFT-N Hann window, from Red

	;-- read a signed little-endian 16-bit sample at byte offset ofs
	pt-read-s16: func [b [byte-ptr!] ofs [integer!] return: [integer!] /local lo hi v [integer!]][
		ofs: ofs + 1
		lo: as integer! b/ofs
		ofs: ofs + 1
		hi: as integer! b/ofs
		v: (hi << 8) or lo
		if v >= 32768 [v: v - 65536]
		v
	]

	;-- allocate everything once
	pt-rs-init: func [return: [integer!] /local i [integer!]][
		pt-ctx: xmp_create_context
		if null? pt-ctx [return 1]
		;-- SDL_Init's bool comes back in AL with garbage upper EAX; R/S not/unless
		;-- misread that non-canonical logic!, so gate on the driver string, not the return
		SDL_Init SDL-INIT-AUDIO
		if null? SDL_GetCurrentAudioDriver [return 2]
		
		pt-fib: allocate XMP-FRAME-INFO-SIZE
		pt-fi:  as xmp-frame-info! pt-fib
		pt-mib: allocate XMP-MODULE-INFO-SIZE
		pt-rb-end:   as int-ptr! allocate PT-RING-DEPTH * 4
		pt-rb-pos:   as int-ptr! allocate PT-RING-DEPTH * 4
		pt-rb-pat:   as int-ptr! allocate PT-RING-DEPTH * 4
		pt-rb-row:   as int-ptr! allocate PT-RING-DEPTH * 4
		pt-rb-nrows: as int-ptr! allocate PT-RING-DEPTH * 4
		pt-rb-bpm:   as int-ptr! allocate PT-RING-DEPTH * 4
		pt-rb-spd:   as int-ptr! allocate PT-RING-DEPTH * 4
		pt-rb-gvol:  as int-ptr! allocate PT-RING-DEPTH * 4
		pt-rb-time:  as int-ptr! allocate PT-RING-DEPTH * 4
		pt-rb-vol:   allocate PT-RING-DEPTH * 64
		pt-rb-note:  allocate PT-RING-DEPTH * 64
		pt-rb-scope: allocate PT-RING-DEPTH * PT-SCOPE-N
		pt-cv: allocate 64
		pt-cn: allocate 64
		pt-cs: allocate PT-SCOPE-N
		pt-spec-coeff: as float-ptr! allocate PT-NB * 8
		pt-spec-mag:   as float-ptr! allocate PT-NB * 8
		pt-fft-buf:    as float-ptr! allocate PT-FFT-N * 8
		pt-spec-win:   as float-ptr! allocate PT-FFT-N * 8
		
		i: 1  while [i <= 64][pt-cv/i: null-byte  pt-cn/i: null-byte  i: i + 1]
		i: 1  while [i <= PT-SCOPE-N][pt-cs/i: null-byte  i: i + 1]
		i: 1  while [i <= PT-NB][pt-spec-coeff/i: 0.0  pt-spec-mag/i: 0.0  i: i + 1]
		i: 1  while [i <= PT-FFT-N][pt-spec-win/i: 1.0  i: i + 1]
		pt-inited?: yes
		0
	]

	pt-rs-reset-stream: func [][
		if pt-opened? [SDL_ClearAudioStream pt-strm]
		pt-total:  0
		pt-head:   0
		pt-tail:   0
		pt-ended?: no
	]

	;-- after a module is loaded: read info, start player, open/clear stream
	pt-rs-open: func [return: [integer!] /local r [integer!]][
		xmp_get_module_info pt-ctx as int-ptr! pt-mib
		pt-modp:  xmp-modinfo-mod pt-mib
		pt-vbase: xmp-modinfo-volbase pt-mib
		pt-nchan: xmp-mod-chn pt-modp
		
		if pt-vbase <= 0 [pt-vbase: 64]
		if pt-nchan <= 0 [pt-nchan: 4]
		if pt-nchan > 64 [pt-nchan: 64]
		r: xmp_start_player pt-ctx 44100 0
		if r <> 0 [return r]
		xmp_get_frame_info pt-ctx (as int-ptr! pt-fib)
		pt-dur: pt-fi/total-time
		
		unless pt-opened? [
			pt-spec/format:   SDL-AUDIO-S16
			pt-spec/channels: 2
			pt-spec/freq:     44100
			pt-strm: SDL_OpenAudioDeviceStream SDL-AUDIO-DEFAULT-PLAYBACK pt-spec null null
			if null? pt-strm [return 99]
			SDL_ResumeAudioStreamDevice pt-strm
			pt-opened?: yes
		]
		pt-rs-reset-stream
		0
	]

	;-- store the current frame_info into ring slot `pt-head`
	pt-rs-record: func [/local slot sl i base bi nsamp idx sv s8 [integer!]][
		slot: pt-head // PT-RING-DEPTH
		sl:   slot + 1
		pt-rb-end/sl:   pt-total
		pt-rb-pos/sl:   pt-fi/pos
		pt-rb-pat/sl:   pt-fi/pattern
		pt-rb-row/sl:   pt-fi/row
		pt-rb-nrows/sl: pt-fi/num-rows
		pt-rb-bpm/sl:   pt-fi/bpm
		pt-rb-spd/sl:   pt-fi/speed
		pt-rb-gvol/sl:  pt-fi/volume
		pt-rb-time/sl:  pt-fi/time
		
		base: slot * 64
		i: 0
		while [i < 64][
			bi: base + i + 1
			either i < pt-nchan [
				pt-rb-vol/bi:  as byte! xmp-chan-vol  pt-fib i
				pt-rb-note/bi: as byte! xmp-chan-note pt-fib i
			][
				pt-rb-vol/bi:  null-byte
				pt-rb-note/bi: null-byte
			]
			i: i + 1
		]
		;-- decimate left channel into the scope snippet
		nsamp: pt-fi/buffer-size / 4
		base:  slot * PT-SCOPE-N
		i: 0
		while [i < PT-SCOPE-N][
			bi: base + i + 1
			either nsamp > 0 [
				idx: (i * nsamp) / PT-SCOPE-N
				sv:  pt-read-s16 pt-fi/buffer (idx * 4)
				s8:  (sv / 256) + 128
				if s8 < 0   [s8: 0]
				if s8 > 255 [s8: 255]
			][
				s8: 128
			]
			pt-rb-scope/bi: as byte! s8
			i: i + 1
		]
		pt-head: pt-head + 1
	]

	;-- Goertzel spectrum: PT-NB band magnitudes(^2) from the last frame's PCM
	pt-rs-spectrum: func [
		/local
			bufp [byte-ptr!]
			n j j1 i i1 iv [integer!]
			x s0 s1 s2 cf m [float!]
	][
		unless pt-opened? [exit]
		n: pt-fi/buffer-size / 4
		if n > PT-FFT-N [n: PT-FFT-N]
		if n <= 0 [exit]
		
		bufp: pt-fi/buffer
		j: 0
		while [j < n][
			j1: j + 1
			iv: pt-read-s16 bufp (j * 4)
			x:  as float! iv
			pt-fft-buf/j1: x / 32768.0 * pt-spec-win/j1   ;-- Hann window
			j: j + 1
		]
		i: 0
		while [i < PT-NB][
			i1: i + 1
			cf: pt-spec-coeff/i1
			s1: 0.0
			s2: 0.0
			j: 0
			while [j < n][
				j1: j + 1
				x:  pt-fft-buf/j1
				s0: x + (cf * s1) - s2
				s2: s1
				s1: s0
				j: j + 1
			]
			m: (s1 * s1) + (s2 * s2) - (cf * s1 * s2)
			pt-spec-mag/i1: m
			i: i + 1
		]
	]

	;-- render frames until the SDL queue holds ~PT-QTARGET bytes
	pt-rs-pump: func [return: [logic!] /local r q [integer!]][
		unless pt-opened? [return yes]
		if pt-ended? [return yes]
		q: SDL_GetAudioStreamQueued pt-strm
		
		while [all [not pt-ended?  q < PT-QTARGET]][
			r: xmp_play_frame pt-ctx
			either r = 0 [
				xmp_get_frame_info pt-ctx (as int-ptr! pt-fib)
				either all [not pt-loopf?  pt-fi/loop-count > 0][
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
		unless pt-ended? [pt-rs-spectrum]
		pt-ended?
	]

	;-- surface the snapshot that is actually audible right now
	pt-rs-sync: func [/local played q best k ke slot sl i ci base bi [integer!]][
		unless pt-opened? [exit]
		q: SDL_GetAudioStreamQueued pt-strm
		played: pt-total - q
		best: -1
		k: pt-tail
		while [k < pt-head][
			ke: k // PT-RING-DEPTH + 1
			if pt-rb-end/ke <= played [best: k]
			k: k + 1
		]
		if best < 0 [exit]
		
		slot: best // PT-RING-DEPTH
		sl:   slot + 1
		pt-cur-pos:   pt-rb-pos/sl
		pt-cur-pat:   pt-rb-pat/sl
		pt-cur-row:   pt-rb-row/sl
		pt-cur-nrows: pt-rb-nrows/sl
		pt-cur-bpm:   pt-rb-bpm/sl
		pt-cur-spd:   pt-rb-spd/sl
		pt-cur-gvol:  pt-rb-gvol/sl
		pt-cur-time:  pt-rb-time/sl
		base: slot * 64
		i: 0
		while [i < 64][
			bi: base + i + 1
			ci: i + 1
			pt-cv/ci: pt-rb-vol/bi
			pt-cn/ci: pt-rb-note/bi
			i: i + 1
		]
		base: slot * PT-SCOPE-N
		i: 0
		while [i < PT-SCOPE-N][
			bi: base + i + 1
			ci: i + 1
			pt-cs/ci: pt-rb-scope/bi
			i: i + 1
		]
		pt-tail: best
	]

	;-- zero the surfaced visual state (VU vols + spectrum mags) -> bars ease down
	pt-rs-clear-state: func [/local i [integer!]][
		pt-cur-pos:  0
		pt-cur-pat:  0
		pt-cur-row:  0
		pt-cur-time: 0
		i: 1
		while [i <= 64][
			pt-cv/i: null-byte
			pt-cn/i: null-byte
			i: i + 1
		]
		i: 1
		while [i <= PT-NB][
			pt-spec-mag/i: 0.0
			i: i + 1
		]
		i: 1
		while [i <= PT-SCOPE-N][
			pt-cs/i: as byte! 128
			i: i + 1
		]
	]
]

;===============================================================================
;  routine! bridges  (Red-callable)
;===============================================================================
pt-init: routine [return: [integer!]][pt-rs-init]
pt-pump: routine [return: [logic!]][pt-rs-pump]
pt-sync: routine [][pt-rs-sync]

pt-load-mem: routine [bin [binary!] return: [integer!] /local p [byte-ptr!] n r [integer!]][
	if pt-loaded? [
		xmp_end_player     pt-ctx
		xmp_release_module pt-ctx
		pt-loaded?: no
	]
	p: binary/rs-head bin
	n: binary/rs-length? bin
	r: xmp_load_module_from_memory pt-ctx (as int-ptr! p) n
	if r <> 0 [return r]
	pt-loaded?: yes
	pt-rs-open
]

;-- getters (read the synced snapshot)
pt-pos:      routine [return: [integer!]][pt-cur-pos]
pt-pattern:  routine [return: [integer!]][pt-cur-pat]
pt-row:      routine [return: [integer!]][pt-cur-row]
pt-numrows:  routine [return: [integer!]][pt-cur-nrows]
pt-bpm:      routine [return: [integer!]][pt-cur-bpm]
pt-speed:    routine [return: [integer!]][pt-cur-spd]
pt-gvol:     routine [return: [integer!]][pt-cur-gvol]
pt-time-ms:  routine [return: [integer!]][pt-cur-time]
pt-channels: routine [return: [integer!]][pt-nchan]
pt-volbase:  routine [return: [integer!]][pt-vbase]
pt-cvol:     routine [i [integer!] return: [integer!]][i: i + 1  as integer! pt-cv/i]
pt-cnote:    routine [i [integer!] return: [integer!]][i: i + 1  as integer! pt-cn/i]
pt-scope:    routine [i [integer!] return: [integer!]][i: i + 1  as integer! pt-cs/i]
pt-set-coeff: routine [i [integer!] c [float!]][i: i + 1  pt-spec-coeff/i: c]
pt-set-win:   routine [i [integer!] w [float!]][i: i + 1  pt-spec-win/i: w]
pt-band:      routine [i [integer!] return: [float!]][i: i + 1  pt-spec-mag/i]
pt-len:      routine [return: [integer!]][either null? pt-modp [0][xmp-mod-len  pt-modp]]
pt-npat:     routine [return: [integer!]][either null? pt-modp [0][xmp-mod-npat pt-modp]]
pt-ins:      routine [return: [integer!]][either null? pt-modp [0][xmp-mod-ins  pt-modp]]
pt-smp:      routine [return: [integer!]][either null? pt-modp [0][xmp-mod-smp  pt-modp]]
pt-duration: routine [return: [integer!]][pt-dur]
pt-queued:   routine [return: [integer!]][either pt-opened? [SDL_GetAudioStreamQueued pt-strm][0]]
pt-clear-state: routine [][pt-rs-clear-state]

;-- one byte of a pattern cell : field 0=note 1=ins 2=vol 3=fxt 4=fxp
pt-cell: routine [pat [integer!] chn [integer!] row [integer!] field [integer!] return: [integer!]][
	either null? pt-modp [0][xmp-event pt-modp pat chn row field]
]

;-- strings
pt-songname: routine [return: [string!] /local cs [c-string!]][
	either null? pt-modp [cs: ""][cs: xmp-mod-name pt-modp]
	string/load-at cs (length? cs) (as cell! stack/arguments) UTF-8
]

pt-modtype: routine [return: [string!] /local cs [c-string!]][
	either null? pt-modp [cs: ""][cs: xmp-mod-type pt-modp]
	string/load-at cs (length? cs) (as cell! stack/arguments) UTF-8
]

;-- transport
pt-stop:       routine [][pt-rs-reset-stream]
pt-restart:    routine [][xmp_restart_module pt-ctx  pt-rs-reset-stream]
pt-setpos:     routine [n [integer!]][xmp_set_position pt-ctx n  pt-rs-reset-stream]
pt-next:       routine [][xmp_next_position pt-ctx  pt-rs-reset-stream]
pt-prev:       routine [][xmp_prev_position pt-ctx  pt-rs-reset-stream]
pt-seek:       routine [ms [integer!]][xmp_seek_time pt-ctx ms  pt-rs-reset-stream]
pt-pause-dev:  routine [][if pt-opened? [SDL_PauseAudioStreamDevice  pt-strm]]
pt-resume-dev: routine [][if pt-opened? [SDL_ResumeAudioStreamDevice pt-strm]]
pt-set-loop:   routine [v [integer!]][either v = 0 [pt-loopf?: no][pt-loopf?: yes]]
pt-set-gain:   routine [g [float!]][if pt-opened? [SDL_SetAudioStreamGain pt-strm (as float32! g)]]   ;-- output gain, leaves the meters honest

pt-quit: routine [][
	if pt-loaded? [xmp_end_player pt-ctx  xmp_release_module pt-ctx]
	unless null? pt-ctx [xmp_free_context pt-ctx]
	if pt-opened? [SDL_DestroyAudioStream pt-strm]
	SDL_Quit
]

;===============================================================================
;  CherryTracker UI  (FlodPro-style Draw layout, 1024x768 real pixels)
;===============================================================================

;-- palette : FlodPro chrome — medium gray, fine 1px bezels on EVERY element,
;-- WHITE labels, sunken GRAY value cells with dark data text (no black text boxes)
col-bg:        158.160.166
col-bevel-lt:  216.218.226
col-bevel-dk:  72.74.84
col-face-dn:   140.142.150        ;-- pressed button face
col-data-bg:   8.8.12             ;-- dark panels : pattern + spectrum wells only
col-data-edge: 58.62.80
col-ink:       18.18.24           ;-- data text in gray cells
col-dim:       92.94.104          ;-- disabled button labels
col-white:     248.249.253        ;-- labels + enabled button text
col-note:      104.138.255        ;-- pattern text (FlodPro blue)
col-row-hi-bg: 44.56.118
col-row-hi-tx: white
col-vu-green:  58.228.92
col-vu-yellow: 238.220.60
col-vu-orange: 248.150.46
col-vu-red:    240.66.52
col-vu-dark:   30.36.54
col-vu-well:   10.12.18           ;-- near-black recessed frame behind each VU bar
col-vu-cap:    188.192.200        ;-- spectrum peak cap base
col-accent:    250.182.64
col-cherry-t:  202.80.92          ;-- wordmark : cherry red, top of the glyph shade
col-cherry-b:  142.38.50          ;-- ... bottom
col-stem-t:    128.148.66         ;-- wordmark : olive stem green, top
col-stem-b:    84.104.38          ;-- ... bottom

;-- fonts : Consolas (chrome) + Segoe UI Symbol (monochrome glyphs take the gradient pen)
fnt-mono: make font! [name: "Consolas" style: 'bold]
fnt-sym:  make font! [name: "Segoe UI Symbol" style: 'bold]
fnt-logo: make fnt-mono [size: 24]
fnt-lbl:  make fnt-mono [size: 13]
fnt-ver:  make fnt-mono [size: 11]              ;-- version tag beside the wordmark
fnt-val:  make fnt-mono [size: 15]
fnt-btn:  make fnt-mono [size: 14]
fnt-chan: make fnt-mono [size: 11]              ;-- CH numbers : shrunk for narrow columns
fnt-pat:  make fnt-mono [size: 14 style: none]  ;-- pattern grid : non-bold
fnt-icon: make fnt-sym  [size: 15]
fnt-icon-big: make fnt-sym [size: 20]           ;-- ↻ renders small : upsize it
fnt-note: make fnt-sym  [size: 20]              ;-- 🎶 wordmark flourish


;-- layout (1024 x 768 design) : every region is an origin + size pair ---------
win-size: 1024x768
hd-org:   8x6          ;-- header bar
hd-size:  1008x44
pp-org:   8x58         ;-- param panel (left) : 9 rows of label + value box
btn-size: 158x26
sp-org:   364x124      ;-- spectrum analyzer
sp-size:  652x166
nm-org:   8x298        ;-- 3 name rows : Song / File / Tracker
nm-size:  1008x84
ch-org:   8x390        ;-- per-channel columns + row gutter
ch-size:  1008x370
;-- param-panel column grid : value cells span x 132..342 (Position cell starts
;-- after its spinners); the Volume row locks to the SAME grid — groove left
;-- edge at 132, value cell right edge at 342
vol-org:    132x264    ;-- volume slider groove (param panel's Volume row)
vol-size:   158x12
seek-org:   600x305    ;-- song seek slider groove (Song name row)
seek-size:  330x12
spin-size:  18x20      ;-- position spinner buttons
spin-l-org: 132x66
spin-r-org: 152x66

;-- transport buttons : single source of truth for drawing AND hit-testing
btns: [
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
SPEC-LO:   0.3         ;-- log10(mag^2) display floor
SPEC-HI:   3.6         ;-- log10(mag^2) display ceiling
SPEC-TILT: 1.5         ;-- progressive HF boost, log10 units across the range (~ +1.9 dB/oct)
SPEC-SAMPLES: 512      ;-- analysis window length, must match PT-FFT-N
SPEC-CAP-HOLD: 30      ;-- frames the peak cap holds before it starts falling (~0.5s @60fps)

;-- spectrum geometry : the dark well hugs the bar field with a 2px margin
spec-bw:   to-integer (sp-size/x - 20) / SPEC-NB
spec-used: (SPEC-NB * spec-bw) - 2
spec-well: as-pair sp-org/x + ((sp-size/x - spec-used) / 2) sp-org/y + 10
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
aw-lbl:  9.0
aw-btn:  9.6
aw-pat:  8.4
aw-chan: 7.6                     ;-- narrow-column CH-number advance (fnt-chan)
th-logo: 38                      ;-- measured line-box heights (for vertical centering)
th-val:  24
th-lbl:  20
th-btn:  22
th-pat:  19
tb-w:    78                      ;-- time cell width (fits "-00:00")
tb-x:    930                     ;-- time cell x (right-aligned in the name rows)

scratch: make face! [
	type: 'base
	size: 600x60
	visible?: no
]

text-size: func [fnt [object!] str [string!] /local sz][
	scratch/font: fnt
	scratch/text: str
	sz: attempt [size-text scratch]
	any [sz 0x0]
]

;-- y offset that vertically centers a line box of height `th` in a cell of height `ch`
cen-y: func [ch [integer!] th [number!]][to integer! (ch - th) / 2]

measure-fonts: func [/local s sz][
	s: "00000000"
	sz: text-size fnt-logo s
	if sz/x > 0 [
		aw-logo: sz/x / 8.0
		th-logo: sz/y
	]
	sz: text-size fnt-val s
	if sz/x > 0 [
		aw-val: sz/x / 8.0
		th-val: sz/y
	]
	sz: text-size fnt-lbl s
	if sz/x > 0 [
		aw-lbl: sz/x / 8.0
		th-lbl: sz/y
	]
	sz: text-size fnt-btn s
	if sz/x > 0 [
		aw-btn: sz/x / 8.0
		th-btn: sz/y
	]
	sz: text-size fnt-pat s
	if sz/x > 0 [
		aw-pat: sz/x / 8.0
		th-pat: sz/y
	]
	sz: text-size fnt-chan s
	if sz/x > 0 [aw-chan: sz/x / 8.0]
	;-- derive the time-cell + seek-groove geometry from the real glyph width
	tb-w: 16 + to integer! aw-val * 6
	tb-x: nm-org/x + nm-size/x - 8 - tb-w
	seek-size: as-pair tb-x - 12 - seek-org/x seek-size/y
]

;-- helpers --------------------------------------------------------------------
;-- one-time builders, used to fill the string tables below; the render loop
;-- itself never builds a string (see the zero-allocation note before render)

pad2: func [n [integer!]][either n < 10 [rejoin ["0" n]][form n]]

hex2: func [v [integer!] /local hi lo][
	if v < 0 [v: 0]
	hi: to integer! v / 16
	lo: v - (hi * 16)
	rejoin [HEXD/(hi + 1) HEXD/(lo + 1)]
]

note-name: func [n [integer!] /local oct idx][
	case [
		n = 0    ["..."]
		n >= 128 ["==="]
		true [
			oct: to integer! (n - 1) / 12
			idx: (n - 1) - (oct * 12)
			rejoin [NOTE-NAMES/(idx + 1) oct + OCT-BASE]
		]
	]
]

fx-type: func [t [integer!]][either all [t >= 0  t <= 35] [FXCH/(t + 1)][#"?"]]

;-- append-into formatters : fill a reused buffer in place, no allocation
pad2-into: func [buf [string!] n [integer!]][
	if n < 10 [append buf #"0"]
	append buf n
]

pad3-into: func [buf [string!] n [integer!]][
	either n < 0 [append buf "000"][
		if n < 100 [append buf #"0"]
		if n < 10  [append buf #"0"]
		append buf n
	]
]

fmt-time-into: func [buf [string!] ms [integer!] /local s m][
	if ms < 0 [ms: 0]
	s: to integer! ms / 1000
	m: to integer! s / 60
	s: s - (m * 60)
	pad2-into buf m
	append buf #":"
	pad2-into buf s
]

;-- string tables + state tags (the note/hex/row/channel tables are filled by `init`)
note-strs: make block! 128
hex-strs:  make block! 256
row-strs:  make block! 256
chw-strs:  make block! 64
chn-strs:  make block! 64
cell-pool: make block! 64          ;-- pattern-cell buffers, grown on demand
state-tags: [idle "IDLE" playing "PLAYING" paused "PAUSED" draining "DRAINING" winddown "WINDDOWN"]
;-- one series per dynamic text cell (declared so compiled mode sees the globals; filled by `init`)
pos-buf: pat-buf: npat-buf: chn-buf: inb-buf: smp-buf: bpm-buf: spd-buf: vol-buf: el-buf: rem-buf: tot-buf: none

note-str: func [n [integer!]][
	case [
		n = 0    ["..."]
		n >= 128 ["==="]
		true     [note-strs/:n]
	]
]

hex-str: func [v [integer!]][either all [v >= 0  v < 256][hex-strs/(v + 1)][hex-strs/1]]
row-str: func [r [integer!]][either all [r >= 0  r < 256][row-strs/(r + 1)][pad2 r]]

cell-buf: func [i [integer!]][
	while [i > length? cell-pool][append/only cell-pool make string! 12]
	clear cell-pool/:i
]

;-- fill the string tables + allocate the per-slot text buffers (each dynamic text
;-- cell needs its OWN series). Called once at startup.
init: function [][
	repeat n 127 [append note-strs note-name n]
	repeat v 256 [append hex-strs hex2 v - 1]
	repeat r 256 [append row-strs pad2 r - 1]
	repeat c 64 [
		append chw-strs rejoin ["CH" c]
		append chn-strs form c
	]
	foreach [buf size] [
		pos-buf 12  pat-buf 8  npat-buf 8  chn-buf 8  inb-buf 8  smp-buf 8
		bpm-buf 8   spd-buf 8  vol-buf 8   el-buf 8   rem-buf 8   tot-buf 8
	][set buf make string! size]
]

;-- every emit-* helper APPENDS its draw code into `out` (compose/into writes
;-- straight into the frame block : no intermediate block is ever allocated)
emit-bevel: func [out [block!] org [pair!] size [pair!] face [tuple!] lt [tuple!] dk [tuple!] /local tr bl br][
	tr: org + (size * 1x0)
	bl: org + (size * 0x1)
	br: org + size
	compose/into [
		pen off fill-pen (face) box (org) (br)
		pen (lt) line (org) (tr) line (org) (bl)
		pen (dk) line (bl) (br) line (tr) (br)
	] tail out
]

emit-sunken: func [out [block!] org [pair!] size [pair!] /local tr bl br][
	tr: org + (size * 1x0)
	bl: org + (size * 0x1)
	br: org + size
	compose/into [
		pen off fill-pen (col-data-bg) box (org) (br)
		pen (col-bevel-dk) line (org) (tr) line (org) (bl)
		pen (col-bevel-lt) line (bl) (br) line (tr) (br)
	] tail out
]

emit-sunken-strip: func [out [block!] org [pair!] size [pair!]][
	emit-bevel out org size col-bg col-bevel-dk col-bevel-lt
]

emit-val-box: func [out [block!] org [pair!] size [pair!] txt [string!]][
	emit-sunken-strip out org size
	compose/into [
		pen (col-ink) font fnt-val text (as-pair org/x + 6 org/y + cen-y size/y th-val) (txt)
	] tail out
]

;-- right-aligned variant of emit-val-box
emit-val-box-r: func [out [block!] org [pair!] size [pair!] txt [string!] /local tx][
	tx: org/x + size/x - 7 - (to integer! (aw-val * length? txt))
	emit-sunken-strip out org size
	compose/into [
		pen (col-ink) font fnt-val text (as-pair tx org/y + cen-y size/y th-val) (txt)
	] tail out
]

;-- white label + drop shadow (caller sets the font)
emit-lbl-text: func [out [block!] pos [pair!] txt [string!]][
	compose/into [
		pen  (0.0.0.150)
		text (pos + 1x1) (txt)
		pen  (col-white)
		text (pos) (txt)
	] tail out
]

;-- mode = 'up | 'dn (pressed) | 'dis (disabled)
emit-btn: func [out [block!] org [pair!] size [pair!] lbl [string!] mode [word!] /local lx ly][
	either mode = 'dn [
		emit-bevel out org size col-face-dn col-bevel-dk col-bevel-lt
	][
		emit-bevel out org size col-bg col-bevel-lt col-bevel-dk
	]
	lx: to integer! (size/x - (aw-btn * length? lbl)) / 2
	ly: cen-y size/y th-btn
	if mode = 'dn [
		lx: lx + 1
		ly: ly + 1
	]
	append out [font fnt-btn]
	either mode = 'dis [
		compose/into [
			pen (col-dim) text (org + (as-pair lx ly)) (lbl)
		] tail out
	][
		emit-lbl-text out org + as-pair lx ly lbl
	]
]
icon-glyphs: ["PLAY" "▶" "PAUSE" "❚❚" "STOP" "■" "LOOP" "↻"]
icon-ink: make block! 8                ;-- glyph -> ink-top + ink-bottom (for true centring)
icon-szs: make block! 8                ;-- glyph -> measured size (the frame loop must not call size-text)

;-- symbol glyphs sit unpredictably inside their em box (the ↻ ink rides low),
;-- so render each one offscreen ONCE and record its real vertical ink bounds
measure-icon-inks: function [][
	clear icon-ink
	clear icon-szs
	foreach [lbl gl] icon-glyphs [
		fname: either gl = "↻" ['fnt-icon-big]['fnt-icon]
		append icon-szs gl
		append icon-szs text-size get fname gl
		img: draw 48x48 compose [
			pen off
			fill-pen white
			box 0x0 48x48
			anti-alias on
			pen black
			font (fname)
			text 0x0 (gl)
		]
		top: none
		bot: none
		repeat y 48 [
			inked?: no
			repeat x 48 [
				c: pick img as-pair x y
				inked?: 600 > (c/1 + c/2 + c/3)
			]
			if inked? [
				if none? top [top: y - 1]
				bot: y - 1
			]
		]
		if top [repend icon-ink [gl  top + bot]]
	]
]

emit-btn-glyph: func [out [block!] org [pair!] size [pair!] gl [string!] mode [word!] /local icol sz lx ly fname oy][
	either mode = 'dn [
		emit-bevel out org size col-face-dn col-bevel-dk col-bevel-lt
	][
		emit-bevel out org size col-bg col-bevel-lt col-bevel-dk
	]
	icol: either mode = 'dis [col-dim][col-ink]
	fname: either gl = "↻" ['fnt-icon-big]['fnt-icon]
	sz: any [select icon-szs gl  14x20]        ;-- measured once by measure-icon-inks
	lx: to integer! ((size/x - sz/x) / 2)
	ly: either oy: select icon-ink gl [
		to integer! (size/y - oy) / 2          ;-- centre the INK, not the em box
	][
		to integer! (size/y - sz/y) / 2
	]
	if mode = 'dn [
		lx: lx + 1
		ly: ly + 1
	]
	compose/into [
		pen (icol) font (fname) text (org + (as-pair lx ly)) (gl)
	] tail out
]

emit-slider: func [out [block!] org [pair!] size [pair!] frac [float!] /local tx][
	if frac < 0.0 [frac: 0.0]
	if frac > 1.0 [frac: 1.0]
	tx: org/x + 1 + to integer! ((size/x - 12) * frac)
	emit-sunken out org size
	emit-bevel out (as-pair tx org/y - 3) (as-pair 10 size/y + 6) col-bg col-bevel-lt col-bevel-dk
]

;-- colour follows ABSOLUTE bar height (not fill ratio); org/size = bar cell, litpx/pk in px
emit-grad-bar: func [out [block!] org [pair!] size [pair!] litpx [integer!] pk [integer!] /local br by ltop pky][
	br: org + size
	by: br/y
	ltop: by - litpx
	compose/into [
		pen off
		fill-pen linear (col-vu-green) 0.0 (col-vu-yellow) 0.5 (col-vu-orange) 0.76 (col-vu-red) 1.0 (as-pair org/x by) (org)
		box (org) (br)
		fill-pen linear (0.0.0.195) 0.0 (0.0.0.255) 0.5 (0.0.0.185) 1.0 (org) (as-pair br/x org/y)
		box (org) (br)
		;-- ghost of the bar above the level
		fill-pen 0.0.0.52
		box (org) (as-pair br/x ltop)
	] tail out
	if pk > 2 [
		pky: by - pk
		compose/into [
			fill-pen linear (col-vu-green) 0.0 (col-vu-yellow) 0.5 (col-vu-orange) 0.76 (col-vu-red) 1.0 (as-pair org/x by) (org)
			box (as-pair org/x pky - 2) (as-pair br/x pky + 1)
		] tail out
	]
]

;-- VU meter : green→red by absolute height, glossy bezel painted on the bar. Draws the
;-- lit bar ONLY — the black well is in emit-chan-notes, under the row highlight.
emit-vu-bar: func [out [block!] org [pair!] size [pair!] litpx [integer!] /local br by bx0 bx1 ltop lw rw][
	br:  org + size
	by:  br/y
	bx0: org/x + 2                 ;-- bar inset inside the thin black frame
	bx1: br/x - 2
	lw: to integer! (bx1 - bx0) * 2 / 10       ;-- light band : left fifth
	if lw < 2 [lw: 2]
	rw: to integer! (bx1 - bx0) * 15 / 100     ;-- dark band : right ~sixth
	if rw < 2 [rw: 2]
	
	if litpx > 1 [
		ltop: by - litpx
		compose/into [
			pen off
			fill-pen linear (col-vu-green) 0.0 (col-vu-yellow) 0.5 (col-vu-orange) 0.76 (col-vu-red) 1.0 (as-pair bx0 by) (as-pair bx0 org/y)
			box (as-pair bx0 ltop) (as-pair bx1 by)
			fill-pen 255.255.255.165
			box (as-pair bx0 ltop) (as-pair bx0 + lw by)
			fill-pen 0.0.0.150
			box (as-pair bx1 - rw ltop) (as-pair bx1 by)
		] tail out
	]
]

;-- static chrome (panels, frames, static labels, logo, wordmark) -------------
build-chrome: function [][
	out: make block! 400
	
	compose/into [pen off fill-pen (col-bg) box 0x0 (win-size)] tail out
	emit-bevel out hd-org hd-size col-bg col-bevel-lt col-bevel-dk
	;-- (the wordmark is drawn by build-wordmark, appended LAST in render :
	;--  this Draw build has no shadow reset, so the shadow must trail the frame)
	;-- param panel + row labels, centered on their value cells (cells at ry-2, 20 high)
	emit-bevel out pp-org 348x232 col-bg col-bevel-lt col-bevel-dk
	append out [font fnt-lbl]
	ry: pp-org/y + 10
	foreach lbl ["Position" "Pattern" "Patterns" "Channels" "Instruments" "Samples" "Tempo" "Speed" "Volume"][
		emit-lbl-text out (as-pair pp-org/x + 12 ry - 2 + cen-y 20 th-lbl) lbl
		ry: ry + 24
	]
	;-- spectrum panel : frame + well
	emit-bevel out sp-org sp-size col-bg col-bevel-lt col-bevel-dk
	emit-sunken out (spec-well - 2x2) (as-pair spec-used + 4 spec-fh + 4)
	;-- the 3 name rows : sunken strips + WHITE right-aligned labels
	emit-sunken-strip out nm-org + 0x0  as-pair nm-size/x 26
	emit-sunken-strip out nm-org + 0x28 as-pair nm-size/x 26
	emit-sunken-strip out nm-org + 0x56 as-pair nm-size/x 26
	lbx: nm-org/x + 100
	lby: cen-y 26 th-lbl
	append out [font fnt-lbl]
	emit-lbl-text out as-pair lbx - to integer! (aw-lbl * 5) nm-org/y + lby      "Song:"
	emit-lbl-text out as-pair lbx - to integer! (aw-lbl * 5) nm-org/y + 28 + lby "File:"
	emit-lbl-text out as-pair lbx - to integer! (aw-lbl * 8) nm-org/y + 56 + lby "Tracker:"
	;-- channels panel
	emit-bevel out ch-org ch-size col-bg col-bevel-lt col-bevel-dk
	emit-sunken out ch-org + 6x6 ch-size - 12x12
	out
]

;-- the real vertical ink bounds [top bottom] (0-based) of `str` in font `fword`
;-- (a WORD! — Draw needs fonts by word), rendered offscreen & pixel-scanned.
;-- lets us align glyphs from DIFFERENT fonts (the Segoe notes vs the Consolas
;-- wordmark) by their ink centre.  First-tick only — never in the frame path.
ink-bounds: function [fword [word!] str [string!] /local img top bot c inked?][
	img: draw 240x90 compose [
		pen off fill-pen white box 0x0 240x90
		anti-alias on pen black font (fword) text 0x0 (str)
	]
	top: bot: none
	repeat y 90 [
		inked?: no
		repeat x 240 [
			c: pick img as-pair x y
			if 600 > (c/1 + c/2 + c/3) [inked?: yes]
		]
		if inked? [
			if none? top [top: y - 1]
			bot: y - 1
		]
	]
	either top [reduce [top bot]][copy [0 0]]
]

;-- the wordmark : 🎶 + "Cherry" (cherry-red) + "Tracker" (stem-green), each glyph
;-- shaded by a gradient pen (fills text AND the monochrome Segoe notes).  Drop shadow
;-- EMULATED by an offset dark pass — Draw `shadow` renders nothing on GDI+.
build-wordmark: function [][
	out: make block! 64
	;-- exact advances via the measurement-DIFFERENCE trick (constant padding cancels)
	cadv: (text-size fnt-logo "CherryCherry") - text-size fnt-logo "Cherry"
	nadv: (text-size fnt-note "🎶🎶")         - text-size fnt-note "🎶"   ;-- leading 🎶 advance
	gap: 8
	ex:  hd-org/x + 14                          ;-- leading 🎶 position
	cx:  ex + nadv/x + gap                       ;-- "Cherry" after the note
	tx:  cx + cadv/x                             ;-- "Tracker" abuts "Cherry" like one word
	ly:  hd-org/y + cen-y hd-size/y th-logo
	gy0: ly + 6
	gy1: ly + th-logo - 6
	;-- centre the note's own ink on the wordmark cap band (Segoe vs Consolas metrics)
	li:  ink-bounds 'fnt-logo "C"
	lc:  to integer! (li/1 + li/2) / 2           ;-- wordmark cap ink centre
	nb:  ink-bounds 'fnt-note "🎶"               ;-- leading 🎶 ink
	bey: ly + lc - to integer! (nb/1 + nb/2) / 2
	;-- small version tag to the right of "Tracker"
	tadv: (text-size fnt-logo "TrackerTracker") - text-size fnt-logo "Tracker"
	ver:  rejoin ["v" system/script/header/version]
	vx:   tx + tadv/x + 10
	vt:   ink-bounds 'fnt-ver ver                 ;-- align the version's ink bottom (baseline)
	vy:   ly + li/2 - vt/2                        ;-- to the title's (li/2 = "C" ink bottom)
	
	compose/into [
		;-- shadow pass (1px offset, translucent dark) for every glyph
		font fnt-note
		pen (0.0.0.150)
		text (as-pair ex + 1 bey + 1) "🎶"
		font fnt-logo
		text (as-pair cx + 1 ly + 1) "Cherry"
		text (as-pair tx + 1 ly + 1) "Tracker"
		;-- 🎶 + Cherry : cherry-red vertical gradient
		font fnt-note
		pen linear (col-cherry-t) 0.0 (col-cherry-b) 1.0 (as-pair ex bey + nb/1) (as-pair ex bey + nb/2)
		text (as-pair ex bey) "🎶"
		font fnt-logo
		pen linear (col-cherry-t) 0.0 (col-cherry-b) 1.0 (as-pair cx gy0) (as-pair cx gy1)
		text (as-pair cx ly) "Cherry"
		;-- Tracker : stem-green vertical gradient (no trailing note)
		pen linear (col-stem-t) 0.0 (col-stem-b) 1.0 (as-pair tx gy0) (as-pair tx gy1)
		text (as-pair tx ly) "Tracker"
		font fnt-ver pen (col-dim) text (as-pair vx vy) (ver)
	] tail out
	out
]

;-- dynamic: param value boxes + position spinners + volume slider
emit-params: function [out [block!]][
	vbx: pp-org/x + 124
	ry:  pp-org/y + 10
	;-- Position row : spinners + pos/len
	emit-btn out spin-l-org spin-size "<" case [
		spin-press = 'l ['dn]
		loaded?         ['up]
		true            ['dis]
	]
	emit-btn out spin-r-org spin-size ">" case [
		spin-press = 'r ['dn]
		loaded?         ['up]
		true            ['dis]
	]
	clear pos-buf
	pad3-into pos-buf pt-pos
	append pos-buf " / "
	pad3-into pos-buf pt-len
	emit-val-box out (as-pair pp-org/x + 168 ry - 2) 166x20 pos-buf
	ry: ry + 24
	clear pat-buf
	pad3-into pat-buf pt-pattern
	emit-val-box out (as-pair vbx ry - 2) 210x20 pat-buf
	ry: ry + 24
	clear npat-buf
	pad3-into npat-buf pt-npat
	emit-val-box out (as-pair vbx ry - 2) 210x20 npat-buf
	ry: ry + 24
	clear chn-buf
	pad2-into chn-buf pt-channels
	emit-val-box out (as-pair vbx ry - 2) 210x20 chn-buf
	ry: ry + 24
	clear inb-buf
	pad2-into inb-buf pt-ins
	emit-val-box out (as-pair vbx ry - 2) 210x20 inb-buf
	ry: ry + 24
	clear smp-buf
	pad2-into smp-buf pt-smp
	emit-val-box out (as-pair vbx ry - 2) 210x20 smp-buf
	ry: ry + 24
	clear bpm-buf
	pad3-into bpm-buf pt-bpm
	emit-val-box out (as-pair vbx ry - 2) 210x20 bpm-buf
	ry: ry + 24
	clear spd-buf
	pad2-into spd-buf pt-speed
	emit-val-box out (as-pair vbx ry - 2) 210x20 spd-buf
	;-- Volume row : slider + value cell
	emit-slider out vol-org vol-size (volume / 100.0)
	clear vol-buf
	append vol-buf volume
	emit-val-box-r out (as-pair vol-org/x + vol-size/x + 8 vol-org/y - 4) 44x20 vol-buf
]

;-- dynamic: transport buttons (mode reflects state, press + disabled)
;-- indexed walk over `btns` : a per-frame foreach would allocate its context
emit-buttons: function [out [block!]][
	i: 1
	while [i < length? btns][
		lbl:  btns/:i
		borg: btns/(i + 1)
		mode: case [
			find btn-reserved lbl ['dis]
			btn-pressed = lbl ['dn]
			all [lbl = "PLAY"  state = 'playing] ['dn]
			all [lbl = "PAUSE" state = 'paused] ['dn]
			all [lbl = "LOOP"  loop?]            ['dn]
			lbl = "LOAD" ['up]
			lbl = "LOOP" ['up]
			loaded?      ['up]
			true         ['dis]
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
emit-spectrum: function [out [block!]][
	iorg: spec-well
	bw:   spec-bw
	barw: bw - 2
	if barw < 2 [barw: 2]
	b: 0
	while [b < SPEC-NB][
		m: pt-band b                               ;-- band magnitude^2 (float)
		level: SPEC-LO
		if m > 1e-6 [
			level: (log-10 m) + ((SPEC-TILT * b) / (SPEC-NB - 1))
			if level < SPEC-LO [level: SPEC-LO]
		]
		frac: (level - SPEC-LO) / (SPEC-HI - SPEC-LO)
		if frac < 0.0 [frac: 0.0]
		if frac > 1.0 [frac: 1.0]
		target: to integer! (frac * spec-fh)
		;-- bar : fast attack, fast decay — the bars pump much quicker than the caps
		lvl: spec-level/(b + 1)
		either target > lvl [
			step: to integer! ((target - lvl) * 55 / 100)
			if step < 1 [step: 1]
			lvl: lvl + step
			if lvl > target [lvl: target]
		][
			step: to integer! ((lvl - target) * 13 / 100)
			if step < 1 [step: 1]
			lvl: lvl - step
			if lvl < target [lvl: target]
		]
		spec-level/(b + 1): lvl
		;-- peak cap : hold at a new peak, then fall
		pk: spec-peak/(b + 1)
		either lvl >= pk [
			pk: lvl                                       ;-- new peak : pin it +
			spec-phold/(b + 1): SPEC-CAP-HOLD             ;-- arm the hold
		][
			either spec-phold/(b + 1) > 0 [
				spec-phold/(b + 1): spec-phold/(b + 1) - 1   ;-- holding : stay put
			][
				pk: pk - 3                                ;-- hold expired : fall (3 px/frame)
			]
		]
		if pk < 0 [pk: 0]
		spec-peak/(b + 1): pk
		emit-grad-bar out (iorg + (as-pair b * bw 0)) (as-pair barw spec-fh) lvl pk
		b: b + 1
	]
]

;-- dynamic: name-row values, seek slider, elapsed / remaining / total times
;-- (name-cache / file-line / type-cache are prepared by load-file, truncation
;-- included — the frame loop only references them)
emit-names: function [out [block!]][
	tot: pt-duration
	el: either find [playing paused draining] state [pt-time-ms][0]
	if el > tot [el: tot]
	vy: cen-y 26 th-val
	
	compose/into [pen (col-ink) font fnt-val
		text (as-pair nm-org/x + 108 nm-org/y + vy)      (name-cache)
		text (as-pair nm-org/x + 108 nm-org/y + 28 + vy) (file-line)
		text (as-pair nm-org/x + 108 nm-org/y + 56 + vy) (type-cache)
	] tail out
	;-- quantize to whole seconds ONCE so both time cells flip in the same frame
	frac: either tot > 0 [(1.0 * el) / tot][0.0]
	emit-slider out seek-org seek-size frac
	els:  to integer! el / 1000
	tots: to integer! tot / 1000
	clear el-buf
	fmt-time-into el-buf (1000 * els)
	emit-val-box-r out (as-pair tb-x nm-org/y + 3)  (as-pair tb-w 20) el-buf
	clear rem-buf
	append rem-buf #"-"
	fmt-time-into rem-buf (1000 * (tots - els))
	emit-val-box-r out (as-pair tb-x nm-org/y + 31) (as-pair tb-w 20) rem-buf
	clear tot-buf
	fmt-time-into tot-buf (1000 * tots)
	emit-val-box-r out (as-pair tb-x nm-org/y + 59) (as-pair tb-w 20) tot-buf
	;-- header state tag, right-aligned + centered
	stag: select state-tags state
	append out [font fnt-lbl]
	emit-lbl-text out (as-pair hd-org/x + hd-size/x - 14 - to integer! (aw-lbl * length? stag) hd-org/y + cen-y hd-size/y th-lbl) stag
]

;-- cached on view-pat/view-row/nch change; view-* may be virtual during winddown
emit-chan-notes: function [out [block!]][
	nch: pt-channels
	if nch <= 0 [nch: 4]
	cpat:  view-pat
	crow:  view-row
	nrows: view-nrows
	cc-x: ch-org/x + 44                          ;-- columns inside the inset, after the row gutter
	cc-w: ch-size/x - 54
	colw: to integer! cc-w / nch
	vuw: to integer! colw * 3 / 10               ;-- match emit-chan-vu
	if vuw > 38 [vuw: 38]
	if vuw < 12 [vuw: 12]
	if vuw > (colw - 8) [vuw: colw - 8]          ;-- ultra-narrow columns (32+ channels)
	if vuw < 4 [vuw: 4]
	notex: vuw + 9                               ;-- note text clears the (wider) VU bar
	showtext?:  colw >= (notex + 76)
	shownotes?: colw >= 46                       ;-- below this, meters only
	rh: 20                                       ;-- >= line height so rows never overlap
	visible: to integer! (ch-size/y - 40) / rh
	if visible < 3 [visible: 3]
	if even? visible [visible: visible - 1]
	half: to integer! (visible - 1) / 2
	;-- VU wells first : they must sit UNDER the row highlight (see emit-vu-bar)
	vuh:   ch-size/y - 40
	vutop: ch-org/y + 30
	c: 0
	while [c < nch][
		cx: cc-x + (c * colw) + 4
		compose/into [pen off fill-pen (col-vu-well) box (as-pair cx vutop) (as-pair cx + vuw vutop + vuh)] tail out
		c: c + 1
	]
	;-- dividers + CH labels (narrow columns : bare number, centred, so the
	;-- label never crosses the divider or the panel edge)
	c: 0
	while [c < nch][
		cx: cc-x + (c * colw)
		if c > 0 [compose/into [pen (col-data-edge) line (as-pair cx ch-org/y + 8) (as-pair cx ch-org/y + ch-size/y - 8)] tail out]
		either colw >= 70 [
			lbl:   chw-strs/(c + 1)
			lx:    cx + notex
			fname: 'fnt-lbl
		][
			lbl: chn-strs/(c + 1)
			;-- shrink the font once a 2-digit number no longer clears the column
			aw: either (2 * aw-lbl) + 6 > colw [
				fname: 'fnt-chan
				aw-chan
			][
				fname: 'fnt-lbl
				aw-lbl
			]
			lx: cx + to integer! (colw - (aw * length? lbl)) / 2
		]
		compose/into [pen (col-white) font (fname) text (as-pair lx ch-org/y + 8) (lbl)] tail out
		c: c + 1
	]
	if all [nrows > 0  cpat >= 0][
		slot: 0
		i: negate half
		while [i <= half][
			rr: crow + i
			cy: (ch-org/y + 28) + ((i + half) * rh)
			if all [rr >= 0  rr < nrows][
				;-- +1px : the fnt-pat ink rides low in its line box, re-centred in the band
				if i = 0 [compose/into [pen off fill-pen (col-row-hi-bg) box (as-pair ch-org/x + 8 cy + 1) (as-pair ch-org/x + ch-size/x - 8 cy + rh + 1)] tail out]
				txcol: either i = 0 [col-row-hi-tx][col-note]
				compose/into [pen (txcol) font fnt-pat text (as-pair ch-org/x + 14 cy) (row-str rr)] tail out
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
							either ins = 0 [append buf ".."][append buf hex-str ins]
							append buf #" "
							append buf fx-type pt-cell cpat c rr 3
							append buf hex-str pt-cell cpat c rr 4
							buf
						][note-str nt]
						
						compose/into [pen (txcol) font fnt-pat text (as-pair cx cy) (cell)] tail out
						c: c + 1
					]
				]
			]
			i: i + 1
		]
	]
]

;-- per-channel VU meters (one bar at the left of each channel column)
emit-chan-vu: function [out [block!]][
	nch: pt-channels
	if nch <= 0 [nch: 4]
	vb: pt-volbase
	if vb <= 0 [vb: 64]
	cc-x: ch-org/x + 44                          ;-- keep in sync with emit-chan-notes
	cc-w: ch-size/x - 54
	colw: to integer! (cc-w / nch)
	vuw: to integer! (colw * 3 / 10)
	if vuw > 38 [vuw: 38]
	if vuw < 12 [vuw: 12]
	if vuw > (colw - 8) [vuw: colw - 8]
	if vuw < 4 [vuw: 4]
	vuh:   ch-size/y - 40
	vutop: ch-org/y + 30
	c: 0
	while [c < nch][
		cx: cc-x + (c * colw) + 4
		v: pt-cvol c
		target: to integer! v * vuh / vb
		if target > vuh [target: vuh]
		;-- ease the displayed level toward the target : fast attack, slow decay
		lvl: vu-level/(c + 1)
		either target > lvl [
			step: to integer! ((target - lvl) * VU-ATTACK / 100)
			if step < 1 [step: 1]
			lvl: lvl + step
			if lvl > target [lvl: target]
		][
			step: to integer! ((lvl - target) * VU-DECAY / 100)
			if step < 1 [step: 1]
			lvl: lvl - step
			if lvl < target [lvl: target]
		]
		vu-level/(c + 1): lvl
		emit-vu-bar out (as-pair cx vutop) (as-pair vuw vuh) lvl
		c: c + 1
	]
]

;-- assemble all layers into the ONE persistent frame block (it IS canvas/draw).
;-- clear keeps capacity; every emitted value is immediate or a reused reference,
;-- so a warm frame allocates NOTHING.
render: func [/local n][
	clear frame-tail                        ;-- keep the anti-alias/scale prefix
	append frame-blk chrome-block
	emit-params   frame-blk
	emit-spectrum frame-blk
	emit-buttons  frame-blk
	emit-names    frame-blk
	n: pt-channels
	if any [view-pat <> last-pat  view-row <> last-row  n <> last-nch][
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
;-- rewind + silence; bars ease down + rows scroll out before idle (see tick-frame)
enter-winddown: does [
	pt-restart
	pt-clear-state
	wind-row:  view-row
	wind-tick: 0
	state: 'winddown
]

do-action: func [lbl [string!]][
	switch lbl [
		"PLAY" [
			if all [loaded?  state <> 'playing][
				if state = 'paused [pt-resume-dev]
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
			if all [loaded?  not find [idle winddown] state][
				if state = 'paused [pt-resume-dev]
				enter-winddown
			]
		]
		"PREV" [
			if loaded? [
				if state = 'paused [pt-resume-dev]
				pt-prev
				state: 'playing
			]
		]
		"NEXT" [
			if loaded? [
				if state = 'paused [pt-resume-dev]
				pt-next
				state: 'playing
			]
		]
		"LOOP" [
			loop?: not loop?
			pt-set-loop either loop? [1][0]
		]
		"LOAD" [load-mod]
	]
]

apply-volume: does [pt-set-gain volume / 100.0]

set-vol-from-x: func [dx [integer!] /local v][
	v: to integer! ((dx - vol-org/x) * 100 / vol-size/x)
	if v < 0 [v: 0]
	if v > 100 [v: 100]
	volume: v
	apply-volume
]

;-- seek to the time under design-x `dx` (throttled while dragging)
do-seek-x: func [dx [integer!] /local tot frac ms][
	tot: pt-duration
	if any [not loaded?  tot <= 0][exit]
	frac: (1.0 * (dx - seek-org/x)) / seek-size/x
	if frac < 0.0 [frac: 0.0]
	if frac > 1.0 [frac: 1.0]
	ms: to integer! frac * tot
	if 1200 < absolute (ms - last-seek-ms) [
		last-seek-ms: ms
		if state = 'paused [pt-resume-dev]
		pt-seek ms
		state: 'playing
	]
]

;-- map a logical face offset back to 1024x768 design (inverse of the letterbox transform)
to-design: func [ofs [pair! point2D!]][
	as-pair (ofs/x - fit-ofs/x) / fit-s	(ofs/y - fit-ofs/y) / fit-s
]

pt-on-down: func [ofs [pair! point2D!] /local pos lbl borg][
	pos: to-design ofs
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
				if all [within? pos borg btn-size  not find btn-reserved lbl][
					btn-pressed: lbl                 ;-- visual press; action fires on release
					break
				]
			]
		]
	]
]

pt-on-up: func [ofs [pair! point2D!] /local pos lbl borg][
	pos: to-design ofs
	if btn-pressed [
		foreach [lbl borg] btns [
			if all [lbl = btn-pressed  within? pos borg btn-size][
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

pt-on-over: func [ofs [pair! point2D!] /local d][
	d: to-design ofs
	if vol-drag?  [set-vol-from-x d/x]
	if seek-drag? [do-seek-x d/x]
]

load-file: func [f [file!] /local data res][
	data: attempt [read/binary f]
	case [
		none? data [
			name-cache: "<file not found>"
			loaded?: no
			state: 'idle
		]
		zero? res: pt-load-mem data [
			name-cache: pt-songname
			type-cache: pt-modtype
			file-cache: form second split-path f
			size-cache: rejoin ["(" to integer! (((length? data) + 512) / 1024) " KB)"]
			if empty? trim copy name-cache [name-cache: copy file-cache]
			;-- the name rows show these as-is every frame : truncate + join NOW
			if 40 < length? name-cache [name-cache: copy/part name-cache 40]
			if 34 < length? type-cache [type-cache: copy/part type-cache 34]
			file-line: rejoin [file-cache "  " size-cache]
			loaded?: yes
			if state = 'paused [pt-resume-dev]
			state: 'playing
			view-pat: -1
			view-row: 0
			view-nrows: 0
			last-pat: -2
			last-seek-ms: 0
			vu-level: append/dup make block! 64 0 64
			apply-volume
		]
		true [
			name-cache: rejoin ["<load error " res ">"]
			loaded?: no
			state: 'idle
		]
	]
]

load-mod: function [][
	f: request-file/title "Load module"
	if none? f [exit]
	if block? f [f: first f]
	load-file f
]

;-- one frame : first-tick init, drive the state machine, sync the view, repaint
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
			if pt-pump [state: 'draining]         ;-- decoded to the end : let the queue play out
			pt-sync
		]
		draining [
			pt-sync
			if 1 > pt-queued [enter-winddown]     ;-- tail played : ease everything down
		]
		winddown [
			wind-tick: wind-tick + 1
			if wind-tick >= 2 [
				wind-tick: 0
				wind-row: wind-row + 1              ;-- rows scroll up and out of view
			]
			if wind-row > (view-nrows + 9) [state: 'idle]
		]
	]
	case [
		find [playing draining] state [
			view-pat:   pt-pattern
			view-row:   pt-row
			view-nrows: pt-numrows
		]
		state = 'winddown [view-row: wind-row]
		true []
	]
	render
]

;-- precompute the Goertzel coefficients (2*cos w) + the Hann window in Red,
;-- push them to R/S (no trig needed on the R/S side)
fill-spec-coeffs: function [][
	lr: log-e (SPEC-FMAX / SPEC-FMIN)
	i: 0
	while [i < SPEC-NB][
		frac: either SPEC-NB > 1 [(i * 1.0) / (SPEC-NB - 1)][0.0]
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

chrome-block:   make block! 0         ;-- built on the first tick, after measure-fonts
wordmark-block: make block! 0
;-- the persistent frame block (the zero-allocation loop's single buffer) and
;-- the cached channel layer, rebuilt only when the visible row/pattern moves
frame-blk: make block! 6000
chan-blk:  make block! 1600
frame-tail: none                ;-- set right after the scale prefix, below

;-- Size the canvas = physical(1024x768) / desktop-scale; draw through `scale`.
DPI: 1.0
attempt [
	raw: system/view/screens/1/data
	if number? raw [DPI: either raw > 8.0 [raw / 100.0][1.0 * raw]]
]
if DPI <= 0.0 [DPI: 1.0]
draw-scale: 1.0 / DPI
face-size: as-pair (win-size/x * draw-scale) (win-size/y * draw-scale)

;-- LETTERBOX FIT : scale the 1024x768 design to the largest 4:3 size that fits,
;-- centre it, fill the margins with chrome gray. Recomputed on resize/maximize.
fit-s:   draw-scale             ;-- design -> device scale
fit-ofs: 0x0                    ;-- device-space centring offset (pair!)

recompute-fit: func [sz [pair!]][
	fit-s: min (1.0 * sz/x / win-size/x) (1.0 * sz/y / win-size/y)
	fit-ofs: as-pair
		(sz/x - (win-size/x * fit-s)) / 2
		(sz/y - (win-size/y * fit-s)) / 2
]

;-- (re)build the permanent Draw prefix for canvas size `sz` : full-canvas gray fill
rebuild-prefix: func [sz [pair!]][
	recompute-fit sz
	clear frame-blk
	append frame-blk compose [
		anti-alias on
		pen off fill-pen (col-bg) box 0x0 (sz)
		translate (fit-ofs) scale (fit-s) (fit-s)
	]
	frame-tail: tail frame-blk
]
rebuild-prefix face-size

init
init-rc: pt-init
unless zero? init-rc [print ["*** pt-init failed, code=" init-rc]]
if zero? init-rc [fill-spec-coeffs]
CLI: system/options/args
if all [zero? init-rc  block? CLI  not empty? CLI][load-file to-red-file first CLI]

win: layout compose [
	title "CherryTracker"
	origin 0x0
	canvas: base (face-size) all-over draw []
		on-time [if all [not closing?  canvas/state][tick-frame]]   ;-- rate stays NONE except during a drag
		on-down [pt-on-down event/offset]
		on-over [pt-on-over event/offset]
		on-up   [pt-on-up event/offset]
]

;-- re-letterbox to a new client size `sz` (non-throwing guard, same as the render loop)
relayout: func [sz [pair!]][
	if all [not closing?  canvas/state][
		canvas/size: sz
		rebuild-prefix sz
		render
	]
]

;-- move/resize modal loops block the manual loop but pump WM_TIMER : arm a transient
;-- `rate` timer for the drag so audio+animation keep going; the loop disarms it.
arm-modal-timer: does [unless timer-on? [canvas/rate: 60  timer-on?: yes]]

win/flags: [resize]
win/actors: make object! [
	;-- close : latch `closing?`, kill any timer, silence the device; the loop then exits
	on-close: func [face [object!] event [event!]][
		closing?: yes
		canvas/rate: none
		pt-pause-dev
	]
	;-- during a drag : arm timer + relayout live (EVT_SIZE suppressed mid-drag, so
	;-- on-resize alone won't — on-resizing must)
	on-resizing: func [face [object!] event [event!]][arm-modal-timer  relayout face/size]
	on-moving:   func [face [object!] event [event!]][arm-modal-timer]
	;-- final commit (WM_EXITSIZEMOVE) + maximize / programmatic resize
	on-resize:   func [face [object!] event [event!]][relayout face/size]
]
;-- install the persistent frame block ONCE; later frames only mutate it (auto-repaints)
canvas/draw: frame-blk

;-- Manual loop, NOT a permanent `rate` timer : timer events pumped during the ✕
;-- teardown corrupt Red's try-frame state -> uncaught THROW ("Error 95").  `win/state`
;-- ends the loop; `wait` paces ~60fps.
view/no-wait win
while [win/state][
	if timer-on? [canvas/rate: none  timer-on?: no]   ;-- reclaim rendering from the drag timer
	if all [not closing?  canvas/state][tick-frame]   ;-- close-guard inlined (inert + non-throwing during teardown)
	do-events/no-wait
	if win/state [wait 0:0:0.01]
]

pt-quit
