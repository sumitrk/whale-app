# Hopper MCP Investigation — Muted Audio Capture

## Goal
Understand how Granola captures system audio (specifically Chrome/YouTube) even when the
system is muted — WITHOUT showing the macOS screen-recording toolbar indicator.

## Current State (branch: `feat/per-process-audio-tap`)
The app is a macOS menu-bar transcription tool (Swift + Python/Parakeet STT).
Push-to-talk: hold Fn key → records mic + system audio → transcribes → auto-pastes.

AudioRecorder.swift currently uses **SCStream** (ScreenCaptureKit).

## What We've Tried & Results

### Approach 1: CoreAudio Global Mono Tap (`CATapDescription`)
- API: `AudioHardwareCreateProcessTap` + `CATapDescription(monoGlobalTapButExcludeProcesses: [])`
- Permission bucket: does NOT show in System Settings (dev build bypasses TCC)
- Toolbar indicator: ✅ none
- Muted `say "hello"`: ✅ captured
- Muted YouTube/Chrome: ❌ silent WAV
- **Root cause**: Chrome detects `kAudioDevicePropertyMute` on the output device and
  either zeroes its CoreAudio output or stops sending samples before the tap sees them.

### Approach 2: SCStream (ScreenCaptureKit) — CURRENT CODE
- API: `SCShareableContent.excludingDesktopWindows` + `SCStream` with `capturesAudio=true`
- No `CGRequestScreenCaptureAccess()` called — let SCStream request its own permission
- Permission bucket: ❌ "Screen & System Audio Recording" (kTCCServiceScreenCapture in TCC)
- Toolbar indicator: ❌ shows screen-recording indicator whenever Fn is held
- Muted YouTube/Chrome: ✅ captured
- **Theory**: SCStream hooks into the WindowServer compositor audio path, which Chrome
  doesn't know to mute — hence it bypasses Chrome's mute detection.

### Approach 3: Per-Process CoreAudio Tap (earlier attempt, now reverted)
- API: `CATapDescription(stereoMixdownOfProcesses: [AudioObjectID])` targeting all audio processes
- Found 35 processes, tap confirmed working (logs showed it)
- Muted YouTube/Chrome: ❌ still silent
- Same root cause as Approach 1

## TCC Database Analysis
```
System TCC services present: kTCCServiceAccessibility, kTCCServiceDeveloperTool,
kTCCServiceListenEvent, kTCCServicePostEvent, kTCCServiceScreenCapture,
kTCCServiceSystemPolicyAllFiles

Granola TCC entries:  kTCCServiceAccessibility|com.granola.app  (ONLY this — no ScreenCapture)
ChatGPT TCC entries:  kTCCServiceAccessibility|com.openai.chat  (ONLY this — no ScreenCapture)
Our app TCC entries:  kTCCServiceAccessibility + kTCCServiceScreenCapture
```
→ "System Audio Recording Only" in System Settings is NOT stored in TCC at all.
→ Granola has ZERO kTCCServiceScreenCapture entry.

## Granola Binary Analysis (standard tools)

### Entitlements (`codesign -d --entitlements`)
```xml
com.apple.developer.associated-domains: applinks:notes.granola.ai
com.apple.security.cs.allow-jit: true
com.apple.security.cs.allow-unsigned-executable-memory: true
com.apple.security.device.audio-input: true          ← standard mic only
com.apple.security.personal-information.calendars: true
```
**NO** screen capture entitlement. NO private Apple entitlements.

### Strings found in `granola.node` (native Electron addon)
```
AudioHardwareCreateProcessTap
CATapDescription
initMonoGlobalTapButExcludeProcesses:     ← global mono tap
initStereoGlobalTapButExcludeProcesses:   ← global stereo tap
AudioHardwareCreateAggregateDevice
AudioDeviceCreateIOProcIDWithBlock
ScreenCaptureKitListener                  ← SCStream also present
audio-capture-use-screencapturekit        ← feature FLAG to switch to SCStream
RequestSystemAudioPermission
CombinedAudioCapture
```

### HAL Plugins (`/Library/Audio/Plug-Ins/HAL/`)
- `BlackHole2ch.driver` — installed Feb 7 2025 (before Granola, user-installed independently)
- Granola bundles NO HAL driver of its own

## The Core Mystery
Granola:
1. Uses `initMonoGlobalTapButExcludeProcesses:` (CATapDescription) as primary approach
2. Has a FEATURE FLAG `audio-capture-use-screencapturekit` to switch to SCStream
3. Is in "System Audio Recording Only" bucket (NOT kTCCServiceScreenCapture)
4. Shows NO toolbar recording indicator
5. Yet captures muted Chrome/YouTube audio (confirmed by user)

**If Granola uses CATapDescription globally (same as our Approach 1), why does it capture
Chrome audio when muted when we cannot?**

Possibilities to investigate with Hopper:
A. Does Granola use a different tap position / different CATapDescription variant?
B. Does Granola intercept Chrome at the per-process level with special process selection?
C. Does Granola use the SCStream feature flag by default (despite strings suggesting CATap)?
D. Does Granola patch/hook CoreAudio at a lower level?
E. Is the muted-YouTube capture the user observed actually the SCStream path (flag enabled)?
F. Does Granola set up an aggregate device differently that bypasses mute?

## Hopper / Binary Analysis Results (2026-03-22)

### Files analyzed
- `/Applications/Granola.app/Contents/MacOS/Granola` — tiny Electron launcher stub only; no audio code
- `/Applications/Granola.app/Contents/Resources/native/granola.node` — fat binary (x86_64 + arm64); all audio logic
- `/Applications/Granola.app/Contents/Resources/native/tcc.node` — permission handling
- (`arm64` slice extracted to `/tmp/granola_arm64.node` for disassembly)

---

### Finding 1 — Permission bucket: private TCC API, NOT screen capture

`tcc.node` calls a **private TCC API** directly from
`/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC`:

```
getSystemAudioPermission   (private function)
kTCCServiceAudioCapture    (service string used)
```

This is how Granola lands in **"System Audio Recording Only"** rather than
"Screen & System Audio Recording". It bypasses the public `AVCaptureDevice`
permission prompt and directly requests `kTCCServiceAudioCapture` via TCC's
private API. That service is NOT `kTCCServiceScreenCapture`, which is why
Granola has zero `kTCCServiceScreenCapture` entry in TCC.

---

### Finding 2 — Two audio paths + a feature flag

`CombinedAudioCapture` owns a `systemAudioListener` ivar that is set to one of:

| Listener class          | API used          | Enabled when                     |
|-------------------------|-------------------|----------------------------------|
| `SystemAudioListener`   | CoreAudio CATap   | macOS ≥ 14.2 AND `enableCoreAudio == 1` |
| `ScreenCaptureKitListener` | SCStream       | macOS < 14.2, OR flag off        |

The decision lives in `-[CombinedAudioCapture startSystemCapture:]`:

```arm64
; macOS version check: ≥ 14.2?
bl  ___isPlatformVersionAtLeast   ; args: (1, 14, 2, 0)
cbz w0, SCStreamPath              ; too old → fall back to SCStream

; flag check: enableCoreAudio?
ldrb w8, [x20, #0x79a0]          ; load enableCoreAudio byte
cmp  w8, #0x1
b.ne SCStreamPath                 ; flag off → SCStream

; → use SystemAudioListener (CATap)
ldr  x0, [x8, #0xae0]  ; Objc class ref: SystemAudioListener
```

`enableCoreAudio` is set by `-[CombinedAudioCapture enableCoreAudio:]` which is
called from JavaScript via the `audio-capture-use-coreaudio` feature flag.

---

### Finding 3 — How the CATap is set up (the key disassembly)

`-[SystemAudioListener setupTap]` (arm64, address `0x17e78`):

```arm64
; 1. Alloc CATapDescription
ldr  x0, [x8, #0xb30]           ; CATapDescription class
bl   _objc_alloc
ldr  x2, [x2, #0xa0]            ; ___NSArray0__struct  (empty array → exclude nobody)
bl   "_objc_msgSend$initMonoGlobalTapButExcludeProcesses:"
mov  x19, x0                    ; save tap description

; 2. Set name
ldr  x2, [x8, #0xfa8]           ; "Granola-Audio-Tap"
bl   "_objc_msgSend$setName:"

; 3. *** SET MUTE BEHAVIOR = 0 (CATapUnmuted) ***
mov  x0, x19
mov  x2, #0x0                   ; CATapUnmuted = 0
bl   "_objc_msgSend$setMuteBehavior:"

; 4. Set private tap
mov  x0, x19
mov  w2, #0x1                   ; privateTap = YES
bl   "_objc_msgSend$setPrivate:"

; 5. Platform gate (macOS ≥ 14.2 already confirmed by caller)
; 6. Create the tap
bl   _AudioHardwareCreateProcessTap
```

Then `-[SystemAudioListener setupAggregateDevice:]`:

```arm64
; Build NSDictionary with 3 keys (name, UID based on UUID, tap sub-device)
bl   "_objc_msgSend$dictionaryWithObjects:forKeys:count:"  ; count = 3
bl   _AudioHardwareCreateAggregateDevice   ; "Granola-Aggregate-Audio-Device"
```

Then `-[SystemAudioListener startAudioCapture:aggregateDeviceID:]`:

```arm64
bl   _AudioObjectGetPropertyData    ; read format from aggregate device
bl   _AudioDeviceCreateIOProcIDWithBlock  ; register IOProc on aggregate device
bl   _AudioDeviceStart               ; start pulling audio
```

---

### Finding 4 — Why `CATapUnmuted` solves the muted-Chrome problem

From `CATapDescription.h` (SDK):

```objc
typedef NS_ENUM(NSInteger, CATapMuteBehavior) {
    CATapUnmuted = 0,        // captured AND sent to hardware  ← Granola uses this
    CATapMuted = 1,          // captured but NOT sent to hardware
    CATapMutedWhenTapped = 2 // captured + sent until a client reads the tap
};
```

The tap operates **before** the hardware volume/mute stage. `CATapUnmuted`
means the process's audio is both captured by the tap AND played through the
hardware normally. The system mute/volume control is applied downstream of
the tap, so:

- Chrome renders audio → sends PCM to CoreAudio HAL
- Tap sees raw PCM **before** volume scaling or hardware mute ✅
- Hardware applies mute → speakers silent (as user expects)
- Our tap buffer has the full audio regardless ✅

**Why our Approach 1 got silence**: We created the tap but likely never set
up the aggregate device + IOProc consumer chain. Without an active IOProc
reading from the aggregate device that wraps the tap, the tap's ring buffer
never gets drained and no data is delivered. The muted-Chrome issue was a
red herring; the missing piece was the aggregate device + `AudioDeviceStart`.

---

### Finding 5 — `setPrivate: YES` hides the tap

From the SDK header:
```objc
@property BOOL privateTap;  // "only visible to the client process that created the tap"
```

Setting `privateTap = YES` means the tap doesn't appear in system-wide
AudioObject enumeration. This likely prevents the OS from showing any
indicator or listing it in System Settings under a recording category.

---

### Summary: The full recipe Granola uses

1. **Permission**: call `getSystemAudioPermission` via private TCC framework with
   `kTCCServiceAudioCapture` → lands in "System Audio Recording Only" bucket,
   NOT screen capture → no toolbar indicator
2. **Tap**: `CATapDescription.initMonoGlobalTapButExcludeProcesses: []`
   - `muteBehavior = CATapUnmuted` (tap before mute stage → captures "muted" audio)
   - `privateTap = YES` (invisible to other processes)
3. **Aggregate device**: `AudioHardwareCreateAggregateDevice` wrapping the tap
4. **IOProc**: `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart` to consume audio
5. **Platform gate**: whole CATap path requires macOS 14.2+; falls back to
   SCStream on older versions

### What this means for our implementation

To replicate Granola's behavior we need ALL of:
- `CATapDescription(monoGlobalTapButExcludeProcesses: [])` ← already doing this
- `.muteBehavior = CATapUnmuted` ← may already be default, but set explicitly
- `.privateTap = true` ← we may be missing this
- `AudioHardwareCreateAggregateDevice` wrapping the tap ← **likely missing in our Approach 1**
- `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart` on the aggregate ← **likely missing**
- For the permission bucket: we need `kTCCServiceAudioCapture` which appears to
  be what the public "System Audio Recording" permission prompt grants when you
  call `AudioHardwareCreateProcessTap` on macOS 14.2+ — no private API needed
  if the OS prompt is allowed to fire naturally.

---

## What To Do With Hopper

Target binary: `/Applications/Granola.app/Contents/MacOS/Granola`
But the interesting code is in the native addon: look for `granola.node` inside the app bundle.

```bash
find /Applications/Granola.app -name "*.node" 2>/dev/null
```

### Key functions to find and decompile in Hopper:
1. `RequestSystemAudioPermission` — how does it request the "System Audio Recording Only" permission?
2. `CombinedAudioCapture` — how does it combine multiple audio sources?
3. `ScreenCaptureKitListener` — when/how is SCStream activated?
4. `audio-capture-use-screencapturekit` — where is this flag checked? What triggers it?
5. Any function that calls `AudioHardwareCreateProcessTap` — what parameters?
6. Any function that calls `SCStream startCapture` — does the toolbar indicator appear?

### Specific questions for Hopper to answer:
- When `audio-capture-use-screencapturekit` is FALSE (default), can it capture muted Chrome?
- Is there a different tap position that bypasses Chrome's mute detection?
- Does Granola do anything special to the aggregate device setup?

## Current AudioRecorder.swift
See `TranscribeMeeting/Sources/AudioRecorder.swift` — currently uses SCStream (Approach 2).
The goal is to revert to CATapDescription (Approach 1) but fix the muted-Chrome issue.

## File Structure
```
TranscribeMeeting/
  Sources/
    AppState.swift       — app logic, PTT via Fn key, auto-paste
    AudioRecorder.swift  — audio capture (currently SCStream)
    HotkeyManager.swift  — Fn key PTT + ⌘⇧T toggle
    MenuBarView.swift    — UI
  TranscribeMeeting.entitlements
project.yml              — XcodeGen config (ScreenCaptureKit.framework included)
server/
  transcriber.py         — Python/Parakeet STT server
```

## Ideal Outcome
Replace SCStream with an approach that:
1. Captures system audio even when muted (including Chrome/YouTube) ✅
2. Does NOT show the screen-recording toolbar indicator ✅
3. Appears in "System Audio Recording Only" bucket (not "Screen & System Audio Recording") ✅
4. Uses a public API (no private entitlements required) ✅
