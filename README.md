# Haru for iPhone

A native SwiftUI client for Haru. It talks to the same web door the phone page
uses (`electron/webserver.ts` in haru-desktop, reached over Tailscale at
`https://haruserver.tail6da04d.ts.net`), so nothing on the server had to change.

What it does:

- **Chat** — her replies stream in as she writes them, split into the bubbles
  she would have sent; her face changes with the mood of each line, and she
  says it out loud through her own voice (`/api/speak`). Thumbs up or down on a
  reply, redo her last one, send a photo or a file, or tap the mic and talk
  (recorded as WAV, transcribed by her ears on the server).
- **Status** — where you stand: mood, bond, meters, patience, grudge, what she
  is waiting on (tick things off from here).
- **Diary**, **Her** — her diary and her own things, nights out, likes, wants.
- **More** — her pestering rules (shared with the desktop), location sharing
  with named places, what she remembers, sign out.
- She speaks first while the app is open (`/api/nudge` on open, on return, and
  every four minutes), and, best effort, while it is closed: iOS wakes the app
  for a background refresh now and then, the app asks her, and anything she has
  to say lands as a notification.

## Building

There is no Xcode project checked in. `project.yml` is the project; XcodeGen
turns it into one. Xcode 16 or newer, iOS 17 or newer on the phone.

### With a Mac

```sh
brew install xcodegen
xcodegen generate
open Haru.xcodeproj
```

In Xcode: select the Haru target → Signing & Capabilities → pick your team.
Plug the phone in, pick it as the destination, press Run. The first time, the
phone will ask you to trust the developer certificate in Settings → General →
VPN & Device Management.

### Without a Mac

`.github/workflows/ios.yml` builds an unsigned `.ipa` on GitHub's macOS runner
on every push to `main` (or by hand: Actions → iOS build → Run workflow).
Download the `Haru-unsigned-ipa` artifact from the run, then sign and install
it from the Windows PC with [Sideloadly](https://sideloadly.io) — plug the
phone in, drop the `.ipa` on it, sign in with your Apple ID.

- With a free Apple ID the app expires after 7 days; re-sideload to renew.
  Three sideloaded apps at a time.
- With a paid Apple Developer account ($99/yr) it lasts a year, and that
  account is also what real push notifications would need (below).

Xcode's own errors, if any, show up in the Actions log; the build is the compiler
for this repo.

## First run

Sign-in screen: her address (already filled in), then the same username and
password as the phone page. "Remember this device" is always on — the cookie is
kept on the phone, the same as the page's. The phone must be on the tailnet.

Then allow notifications and, if you want her to know where you are, flip the
switch under More → Where you are and name a place "home".

## What is not here yet

- **Real push notifications.** The phone page uses Web Push; a native app needs
  APNs instead, which needs a paid developer account and a server-side sender
  (a `.p8` key, token-based auth, HTTP/2 to `api.push.apple.com`). Until then
  she relies on background refresh, which iOS runs on its own schedule —
  minutes to hours apart, and not at all in Low Power Mode.
- **Hands-free talk mode.** The page's voice loop (say her name, she wakes,
  speak over her) is not carried over; the mic here is tap-to-talk.
- **The Live2D stage.** Her SVG face is shown instead of the animated model.
