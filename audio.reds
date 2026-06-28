Red/System [
	Title:   "CherryTracker — SDL3 audio output (slim)"
	Author:  "Nenad Rakocevic"
	Purpose: {
        Minimal SDL3 audio-output binding. Just enough to push libxmp's 
        decoded PCM to the default playback device through a device-bound
        audio stream that we feed by hand.

        SDL runs its own internal audio thread and pulls from the stream's
        queue, so the caller only has to keep that queue topped up
        (SDL_GetAudioStreamQueued reports how many bytes are still pending).
        Only SDL_INIT_AUDIO is initialised — no video/event subsystem — so it
        coexists with Red/View's own Win32 message loop.
    }
]

;-- ============================================================
;--  Constants
;-- ============================================================
#define SDL-INIT-AUDIO              00000010h        ;-- SDL3 SDL_INIT_AUDIO
#define SDL-AUDIO-S16               8010h            ;-- signed 16-bit LE
#define SDL-AUDIO-DEFAULT-PLAYBACK  FFFFFFFFh        ;-- SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK (-1)

;-- SDL_AudioSpec — format + channel count + sample rate
SDL-AudioSpec!: alias struct! [
	format   [integer!]                              ;-- SDL_AudioFormat
	channels [integer!]
	freq     [integer!]                              ;-- samples per second
]

;-- ============================================================
;--  Imports
;-- ============================================================
#import [
	"libs/SDL3" cdecl [
		SDL_Init:     "SDL_Init"     [flags [integer!] return: [logic!]]
		SDL_Quit:     "SDL_Quit"     []
		SDL_GetError: "SDL_GetError" [return: [c-string!]]
		;-- steer the audio backend (Red/View holds an STA OLE apartment on the
		;-- main thread; SDL3's default WASAPI wants MTA)
		SDL_SetHint:  "SDL_SetHint"  [name [c-string!] value [c-string!] return: [logic!]]
		SDL_GetNumAudioDrivers:    "SDL_GetNumAudioDrivers"    [return: [integer!]]
		SDL_GetAudioDriver:        "SDL_GetAudioDriver"        [index [integer!] return: [c-string!]]
		SDL_GetCurrentAudioDriver: "SDL_GetCurrentAudioDriver" [return: [c-string!]]

		;-- Open a playback stream already bound to a device. Null callback =
		;-- fed by hand via SDL_PutAudioStreamData; device starts paused.
		SDL_OpenAudioDeviceStream: "SDL_OpenAudioDeviceStream" [
			devid    [integer!]
			spec     [SDL-AudioSpec!]
			callback [int-ptr!]
			userdata [int-ptr!]
			return:  [int-ptr!]                      ;-- SDL_AudioStream*, null on failure
		]
		SDL_ResumeAudioStreamDevice: "SDL_ResumeAudioStreamDevice" [stream [int-ptr!] return: [logic!]]
		SDL_PauseAudioStreamDevice:  "SDL_PauseAudioStreamDevice"  [stream [int-ptr!] return: [logic!]]

		;-- Append samples to the queue. Data is copied, so the caller's
		;-- buffer can be reused immediately.
		SDL_PutAudioStreamData: "SDL_PutAudioStreamData" [
			stream [int-ptr!] buf [byte-ptr!] len [integer!] return: [logic!]
		]
		;-- Bytes queued and not yet consumed by the device.
		SDL_GetAudioStreamQueued: "SDL_GetAudioStreamQueued" [stream [int-ptr!] return: [integer!]]
		;-- Output gain (1.0 = unity). Applied at pull time → affects queued audio
		;-- immediately and does NOT touch the decoded PCM (so VU meters stay honest).
		SDL_SetAudioStreamGain: "SDL_SetAudioStreamGain" [stream [int-ptr!] gain [float32!] return: [logic!]]
		SDL_ClearAudioStream:     "SDL_ClearAudioStream"     [stream [int-ptr!] return: [logic!]]
		SDL_FlushAudioStream:     "SDL_FlushAudioStream"     [stream [int-ptr!] return: [logic!]]
		SDL_DestroyAudioStream:   "SDL_DestroyAudioStream"   [stream [int-ptr!]]
	]
]
