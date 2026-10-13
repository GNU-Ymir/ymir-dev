#!/usr/bin/env bash
# Generates the modules of ysdl3 out of the SDL 3.4 headers
set -euo pipefail

E=$(dirname "$(readlink -f "$0")")
T=$(dirname "$(dirname "$E")")
H=/usr/include/SDL3
I=/usr/include/SDL3_image
D=${1:?usage: build_ysdl3.sh SRC_DIR (the src/sdl3 directory of ysdl3)}

lic() { cat "$E/licence.txt"; echo; }
fns() { python3 "$T/bindfn.py" "$@"; }
en() { python3 "$T/bindtype.py" enum "$@"; echo; }
dfs() { python3 "$T/bindtype.py" defs "$@"; echo; }
td() { python3 "$T/bindtype.py" typedef "$@"; }
st() { python3 "$T/bindtype.py" struct "$@"; echo; }
props() { # the property names of a header, as string constants
    grep -E "^#define $2\s+\"" "$1" | awk '{ printf "pub def %s = %s;\n", $2, $3 }'; echo
}
head_doc() { # module header: the file, then what it binds
    printf '/**\n * %s\n *\n' "$1"
    fold -s -w 113 <<< "$2" | sed 's/ *$//; s/^/ * /'
    printf ' */\n'
}
out() { cat -s > "$D/$1.yr"; }

# ================================================================================================================

{ lic; head_doc SDL_stdinc.h "The memory functions of SDL, the memory it hands over is released with SDL_free. The rest of the C runtime SDL replaces is not bound, Ymir has its own."
cat <<'EOF'
in stdinc;

/**
 * A generic function pointer, the type of the addresses SDL looks up in a library.
 */
pub def SDL_FunctionPointer: fn ()-> void;

/**
 * SDL times are signed, 64-bit integers representing nanoseconds since the Unix epoch (Jan 1, 1970).
 */
pub def SDL_Time: i64;

EOF
fns $H/SDL_stdinc.h --only '^SDL_(malloc|calloc|realloc|free)$'; } | out stdinc

{ lic; head_doc SDL_error.h "Simple error message routines for SDL. SDL_SetError is variadic and SDL_SetErrorV takes a va_list, neither is bound."
echo "in error;"; echo
fns $H/SDL_error.h --skip 'SDL_SetError'; } | out error

{ lic; head_doc SDL_init.h "All SDL programs need to initialize the library before starting to work with it. The main callbacks (SDL_AppInit...) are for programs whose main function SDL provides, they are not bound."
echo "in init;"; echo
td $H/SDL_init.h SDL_InitFlags
dfs $H/SDL_init.h 'SDL_INIT_[A-Z]+' u32
td $H/SDL_init.h SDL_MainThreadCallback
fns $H/SDL_init.h; } | out init

{ lic; head_doc SDL_version.h "Functionality to query the current SDL version, both as headers the app was compiled against, and a library the app is linked to."
cat <<'EOF'
in version;

/**
 * The major version of the SDL headers this binding was written against.
 */
pub def SDL_MAJOR_VERSION = 3;

/**
 * The minor version of the SDL headers this binding was written against.
 */
pub def SDL_MINOR_VERSION = 4;

/**
 * The micro (or patchlevel) version of the SDL headers this binding was written against.
 */
pub def SDL_MICRO_VERSION = 2;

/**
 * The version number of the SDL headers this binding was written against, SDL_VERSIONNUM(3, 4, 2).
 */
pub def SDL_VERSION = 3004002;

EOF
fns $H/SDL_version.h
cat <<'EOF'
/**
 * @params:
 *    - major: the major version number.
 *    - minor: the minor version number.
 *    - patch: the patch version number.
 * @returns: the single number the three version numbers make, as SDL_GetVersion() returns it
 */
pub fn SDL_VERSIONNUM(major: i32, minor: i32, patch: i32)-> i32 {
    major * 1000000 + minor * 1000 + patch
}

/**
 * @returns: the major version of a version number made by SDL_VERSIONNUM
 */
pub fn SDL_VERSIONNUM_MAJOR(version: i32)-> i32 {
    version / 1000000
}

/**
 * @returns: the minor version of a version number made by SDL_VERSIONNUM
 */
pub fn SDL_VERSIONNUM_MINOR(version: i32)-> i32 {
    (version / 1000) % 1000
}

/**
 * @returns: the micro version of a version number made by SDL_VERSIONNUM
 */
pub fn SDL_VERSIONNUM_MICRO(version: i32)-> i32 {
    version % 1000
}
EOF
} | out version

{ lic; head_doc SDL_timer.h "SDL provides time management functionality. It is useful for dealing with (usually) small durations of time."
echo "in timer;"; echo
dfs $H/SDL_timer.h 'SDL_[A-Z]+_PER_[A-Z]+' u64
td $H/SDL_timer.h SDL_TimerID
td $H/SDL_timer.h SDL_TimerCallback
td $H/SDL_timer.h SDL_NSTimerCallback
fns $H/SDL_timer.h; } | out timer

{ lic; head_doc SDL_properties.h "A property is a variable that can be created and retrieved by name at runtime. All properties are part of a property group (SDL_PropertiesID)."
echo "in properties;"; echo
td $H/SDL_properties.h SDL_PropertiesID
en $H/SDL_properties.h SDL_PropertyType
props $H/SDL_properties.h 'SDL_PROP_\w+'
td $H/SDL_properties.h SDL_CleanupPropertyCallback
td $H/SDL_properties.h SDL_EnumeratePropertiesCallback
fns $H/SDL_properties.h; } | out properties

{ lic; head_doc SDL_rect.h "Some helper functions for managing rectangles and 2D points, in both integer and floating point versions. The inline helpers of the header (SDL_PointInRect, SDL_RectEmpty...) are not exported by the library, they are not bound."
echo "in rect;"; echo
st $H/SDL_rect.h SDL_Point
st $H/SDL_rect.h SDL_FPoint
st $H/SDL_rect.h SDL_Rect
st $H/SDL_rect.h SDL_FRect
fns $H/SDL_rect.h; } | out rect

{ lic; head_doc SDL_pixels.h "SDL offers facilities for pixel management. The formats whose name depends on the byte order (SDL_PIXELFORMAT_RGBA32...) are those of a little endian machine. The macros building and reading the format and colorspace numbers are not bound."
echo "in pixels;"; echo
dfs $H/SDL_pixels.h 'SDL_ALPHA_(OPAQUE|TRANSPARENT)' u8
for e in SDL_PixelType SDL_BitmapOrder SDL_PackedOrder SDL_ArrayOrder SDL_PackedLayout SDL_PixelFormat SDL_ColorType \
         SDL_ColorRange SDL_ColorPrimaries SDL_TransferCharacteristics SDL_MatrixCoefficients SDL_ChromaLocation \
         SDL_Colorspace; do
    en $H/SDL_pixels.h $e
done
st $H/SDL_pixels.h SDL_Color
st $H/SDL_pixels.h SDL_FColor
st $H/SDL_pixels.h SDL_Palette
st $H/SDL_pixels.h SDL_PixelFormatDetails
fns $H/SDL_pixels.h; } | out pixels

{ lic; head_doc SDL_blendmode.h "Blend modes decide how two colors will mix together."
echo "in blendmode;"; echo
td $H/SDL_blendmode.h SDL_BlendMode
dfs $H/SDL_blendmode.h 'SDL_BLENDMODE_[A-Z_]+' u32
en $H/SDL_blendmode.h SDL_BlendOperation
en $H/SDL_blendmode.h SDL_BlendFactor
fns $H/SDL_blendmode.h; } | out blendmode

{ lic; head_doc SDL_surface.h "SDL surfaces are buffers of pixels in system RAM. The functions reading or writing an SDL_IOStream are not bound."
cat <<'EOF'
in surface;

use sdl3::{blendmode, pixels, properties, rect};

EOF
td $H/SDL_surface.h SDL_SurfaceFlags
dfs $H/SDL_surface.h 'SDL_SURFACE_[A-Z_]+' u32
en $H/SDL_surface.h SDL_ScaleMode
en $H/SDL_surface.h SDL_FlipMode
st $H/SDL_surface.h SDL_Surface
props $H/SDL_surface.h 'SDL_PROP_\w+'
fns $H/SDL_surface.h --skip-type 'SDL_IOStream'; } | out surface

{ lic; head_doc SDL_video.h "SDL's video subsystem is largely interested in abstracting window management from the underlying operating system. The OpenGL and EGL functions are not bound."
cat <<'EOF'
in video;

use sdl3::{pixels, properties, rect, surface};

EOF
td $H/SDL_video.h SDL_DisplayID
td $H/SDL_video.h SDL_WindowID
en $H/SDL_video.h SDL_SystemTheme
td $H/SDL_video.h SDL_DisplayModeData
st $H/SDL_video.h SDL_DisplayMode
en $H/SDL_video.h SDL_DisplayOrientation
td $H/SDL_video.h SDL_Window
td $H/SDL_video.h SDL_WindowFlags
dfs $H/SDL_video.h 'SDL_WINDOW_(?!SURFACE)[A-Z_]+' u64
dfs $H/SDL_video.h 'SDL_WINDOWPOS_(UNDEFINED|CENTERED)(_MASK)?' u32
dfs $H/SDL_video.h 'SDL_WINDOW_SURFACE_VSYNC_[A-Z]+' i32
en $H/SDL_video.h SDL_FlashOperation
en $H/SDL_video.h SDL_ProgressState
en $H/SDL_video.h SDL_HitTestResult
td $H/SDL_video.h SDL_HitTest
props $H/SDL_video.h 'SDL_PROP_\w+'
fns $H/SDL_video.h --skip '^SDL_(GL|EGL)_'; } | out video

{ lic; head_doc SDL_vulkan.h "Functions for creating Vulkan surfaces on SDL windows. The handles are those of the binding of Vulkan, pointers to the opaque objects of the driver, and the allocation callbacks a pointer to its VkAllocationCallbacks."
cat <<'EOF'
in vulkan;

use sdl3::{stdinc, video};

pub def VkInstance      : *(void);
pub def VkPhysicalDevice: *(void);
pub def VkSurfaceKHR    : *(void);

EOF
# the allocation callbacks are those of the binding of Vulkan, SDL passing them through: a pointer to anything here, a
# record of that name would clash with the one of the Vulkan binding
fns $H/SDL_vulkan.h | sed 's/\*VkAllocationCallbacks/*void/g'; } | out vulkan

{ lic; head_doc SDL_scancode.h "Defines keyboard scancodes."
echo "in scancode;"; echo
en $H/SDL_scancode.h SDL_Scancode; } | out scancode

{ lic; head_doc SDL_keycode.h "Defines constants which identify keyboard keys and modifiers."
echo "in keycode;"; echo
td $H/SDL_keycode.h SDL_Keycode
dfs $H/SDL_keycode.h 'SDLK_\w+' u32
td $H/SDL_keycode.h SDL_Keymod
dfs $H/SDL_keycode.h 'SDL_KMOD_\w+' u16; } | out keycode

{ lic; head_doc SDL_keyboard.h "SDL keyboard management."
cat <<'EOF'
in keyboard;

use sdl3::{keycode, properties, rect, scancode, video};

EOF
td $H/SDL_keyboard.h SDL_KeyboardID
en $H/SDL_keyboard.h SDL_TextInputType
en $H/SDL_keyboard.h SDL_Capitalization
props $H/SDL_keyboard.h 'SDL_PROP_\w+'
fns $H/SDL_keyboard.h; } | out keyboard

{ lic; head_doc SDL_mouse.h "Any GUI application has to deal with the mouse, and SDL provides functions to manage mouse input and the displayed cursor."
cat <<'EOF'
in mouse;

use sdl3::{surface, video};

EOF
td $H/SDL_mouse.h SDL_MouseID
td $H/SDL_mouse.h SDL_Cursor
en $H/SDL_mouse.h SDL_SystemCursor
en $H/SDL_mouse.h SDL_MouseWheelDirection
st $H/SDL_mouse.h SDL_CursorFrameInfo
td $H/SDL_mouse.h SDL_MouseButtonFlags
dfs $H/SDL_mouse.h 'SDL_BUTTON_(LEFT|MIDDLE|RIGHT|X1|X2)' u8
dfs $H/SDL_mouse.h 'SDL_BUTTON_[A-Z0-9]+MASK' u32
td $H/SDL_mouse.h SDL_MouseMotionTransformCallback
fns $H/SDL_mouse.h
cat <<'EOF'
/**
 * @returns: the mask of the button `X` in an SDL_MouseButtonFlags
 */
pub fn SDL_BUTTON_MASK(X: u8)-> SDL_MouseButtonFlags {
    1u32 << cast!u32(X - 1u8)
}
EOF
} | out mouse

{ lic; head_doc SDL_touch.h "SDL offers touch input, on platforms that support it."
echo "in touch;"; echo
td $H/SDL_touch.h SDL_TouchID
td $H/SDL_touch.h SDL_FingerID
en $H/SDL_touch.h SDL_TouchDeviceType
st $H/SDL_touch.h SDL_Finger
cat <<'EOF'
/**
 * The SDL_MouseID for mouse events simulated with touch input.
 */
pub def SDL_TOUCH_MOUSEID = 0xFFFFFFFFu32;

/**
 * The SDL_TouchID for touch events simulated with mouse input.
 */
pub def SDL_MOUSE_TOUCHID = 0xFFFFFFFFFFFFFFFFu64;

EOF
fns $H/SDL_touch.h; } | out touch

{ lic; head_doc SDL_pen.h "SDL pen event handling. SDL provides an API for pressure-sensitive pen (stylus and/or eraser) handling, e.g., for input and drawing tablets or suitably equipped mobile / tablet devices."
echo "in pen;"; echo
td $H/SDL_pen.h SDL_PenID
cat <<'EOF'
/**
 * The SDL_MouseID for mouse events simulated with pen input.
 */
pub def SDL_PEN_MOUSEID = 0xFFFFFFFEu32;

/**
 * The SDL_TouchID for touch events simulated with pen input.
 */
pub def SDL_PEN_TOUCHID = 0xFFFFFFFFFFFFFFFEu64;

EOF
td $H/SDL_pen.h SDL_PenInputFlags
dfs $H/SDL_pen.h 'SDL_PEN_INPUT_[A-Z_0-9]+' u32
en $H/SDL_pen.h SDL_PenAxis
en $H/SDL_pen.h SDL_PenDeviceType
fns $H/SDL_pen.h; } | out pen

{ lic; head_doc SDL_events.h "Event queue management. The identifiers of the devices whose subsystem is not bound (joysticks, audio devices, cameras, sensors) are declared here, for their events."
cat <<'EOF'
in events;

use sdl3::{keyboard, keycode, mouse, pen, scancode, touch, video};

EOF
td $H/SDL_joystick.h SDL_JoystickID
td $H/SDL_audio.h SDL_AudioDeviceID
td $H/SDL_camera.h SDL_CameraID
td $H/SDL_sensor.h SDL_SensorID
en $H/SDL_power.h SDL_PowerState i32
en $H/SDL_events.h SDL_EventType
for e in SDL_CommonEvent SDL_DisplayEvent SDL_WindowEvent SDL_KeyboardDeviceEvent SDL_KeyboardEvent SDL_TextEditingEvent \
         SDL_TextEditingCandidatesEvent SDL_TextInputEvent SDL_MouseDeviceEvent SDL_MouseMotionEvent \
         SDL_MouseButtonEvent SDL_MouseWheelEvent SDL_JoyAxisEvent SDL_JoyBallEvent SDL_JoyHatEvent SDL_JoyButtonEvent \
         SDL_JoyDeviceEvent SDL_JoyBatteryEvent SDL_GamepadAxisEvent SDL_GamepadButtonEvent SDL_GamepadDeviceEvent \
         SDL_GamepadTouchpadEvent SDL_GamepadSensorEvent SDL_AudioDeviceEvent SDL_CameraDeviceEvent SDL_RenderEvent \
         SDL_TouchFingerEvent SDL_PinchFingerEvent SDL_PenProximityEvent SDL_PenMotionEvent SDL_PenTouchEvent \
         SDL_PenButtonEvent SDL_PenAxisEvent SDL_DropEvent SDL_ClipboardEvent SDL_SensorEvent SDL_QuitEvent \
         SDL_UserEvent; do
    st $H/SDL_events.h $e
done
cat "$E/sdl_event.yr"
en $H/SDL_events.h SDL_EventAction
td $H/SDL_events.h SDL_EventFilter
fns $H/SDL_events.h; } | out events

{ lic; head_doc SDL_clipboard.h "SDL provides access to the system clipboard, both for reading information from other processes and publishing information of its own."
echo "in clipboard;"; echo
td $H/SDL_clipboard.h SDL_ClipboardDataCallback
td $H/SDL_clipboard.h SDL_ClipboardCleanupCallback
fns $H/SDL_clipboard.h; } | out clipboard

{ lic; head_doc SDL_image.h "Header file for SDL_image library, linked as SDL3_image. The functions reading or writing an SDL_IOStream, those of the renderer, of the GPU and of the animations are not bound."
cat <<'EOF'
in image;

use sdl3::surface;

EOF
dfs $I/SDL_image.h 'SDL_IMAGE_(MAJOR|MINOR|MICRO)_VERSION' i32
fns $I/SDL_image.h --skip-type 'SDL_IOStream|SDL_Renderer|SDL_Texture|SDL_GPU|IMG_Animation'; } | out image
