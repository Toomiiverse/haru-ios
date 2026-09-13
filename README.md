# Haru for iPhone

A native SwiftUI client for Haru. It talks to the same web door the phone page
uses (`electron/webserver.ts` in haru-desktop, reached over Tailscale at
`https://haruserver.tail6da04d.ts.net`), so nothing on the server had to change.

What it does:

- **Her, on stage** — the phone page's own SVG avatar, generated straight from
  the desktop code (`scripts/sync-avatar.mjs`) so the two never drift: her
  faces crossfade with her mood, she floats, blinks, glances about, looks
  down when you type and at you while she talks. Each face is fetched from
  her server behind the login. Tap the stage to shrink or grow it; hold it to
  reload her.
- **Chat** — her replies stream in as she writes them, split into the bubbles
  she would have sent; her expression changes with the mood of each line, and
  she says it out loud through her own voice (`/api/speak`). Thumbs up or down on a
  reply, redo her last one, send a photo or a file.
- **Talk, hands-free** — tap the mic once and she listens the way the phone
  page's talk mode does: awake for a while after the tap, then asleep until
  you say "Haru" or "Hey Haru" (with or without the rest of the sentence in
  the same breath). Speaking over her cuts her off and she is told so. Her
  ears are the server's Whisper; the wake phrase and the state machine are
  the desktop's. Apple's echo cancellation keeps her own voice from waking
  her. It keeps listening with the screen locked, so stop it when you're
  done (the orange microphone dot says it's on).
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

`.github/workflows/ios.yml` runs `scripts/build-ipa.sh`, which builds an unsigned `.ipa` on GitHub's macOS runner
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

### TestFlight (paid developer account)

The same build script signs the app in the cloud and uploads it to App Store
Connect when the workflow hands it four repository secrets: `ASC_KEY_ID`,
`ASC_ISSUER_ID`, `ASC_KEY_P8` (the App Store Connect API key, Admin role) and
`APPLE_TEAM_ID`. `scripts/arm-testflight.sh` sets them from the `.p8` and
starts a build; `scripts/ios.yml.wanted` is the workflow that passes them (it
has to be copied over `.github/workflows/ios.yml` from a machine whose GitHub
token has the `workflow` scope). Each push to `main` then lands in TestFlight
a few minutes later, build number = the run number. Real push notifications
need a second key: `scripts/install-apns.sh` puts the APNs `.p8` on the
server and sets `apns` in its config.

## First run

Sign-in screen: her address (already filled in), then the same username and
password as the phone page. "Remember this device" is always on — the cookie is
kept on the phone, the same as the page's. The phone must be on the tailnet.

Then allow notifications and, if you want her to know where you are, flip the
switch under More → Where you are and name a place "home".

## Widgets

Her on the home screen (small: face, feeling, bond, energy; medium: her mood
in her own words, the bars, and a mic that opens the ear) and on the lock
screen (a gauge, a two-line strip, an inline line). The `HaruWidget`
extension fetches `/api/status` on its own clock with the cookie the app
leaves in the App Group `group.com.toomiiverse.haru`, and shows the app's
last snapshot until then; taps open the app through `haru://`.

## Share to Haru

From any app's share sheet: a link, some text or a picture, with a line of
your own, into the chat — and her answer back in the sheet. The `HaruShare`
extension uses the same App Group cookie as the widgets; a picture is staged
through `/api/attach` the way the composer does it.

## Siri, Shortcuts, the Action button

A Focus can hold her: Settings → Focus → the one you want → Add Filter →
Haru → "Hold her nudges". Her pushes stay in while that Focus is on and
resume when it ends; the More screen says when a Focus is holding her.

Three verbs, with no server side: "Hey Siri, **tell Haru**" (Siri asks what,
then reads her reply back), "**talk to Haru**" (opens the app with the ear
on — set the Action button to this Shortcut), and "**how is Haru**" (her mood
and where you stand, spoken). They appear in the Shortcuts app under Haru, so
an automation can send her a line when you arrive home, when the car
connects, or when the charger goes in. The intents run in the app's own
process with the saved address and cookie; `haru://` links open the screens.

## Answering from the lock screen

Long-press one of her notifications: every line takes a **Reply** (typed and
sent without opening the app), and a reminder about a thing on your list
takes **Done** as well, which ticks it off. Tapping a reminder opens Status;
tapping anything else opens the chat. The server names the buttons in the
push payload (`category`, and the item under `haru`); the app's own
background-refresh notifications carry the same.

The app answers `haru://` links, for Shortcuts, the Action button and Safari:
`haru://chat`, `haru://talk` (opens the chat and starts listening),
`haru://status`, `haru://diary`, `haru://her`, `haru://more`.

## Her list in Apple Reminders

Under More, **Keep her list in Reminders** makes a list called *Haru* in the
Reminders app that matches hers, both ways. Tasks from `GET /api/agenda`
appear there with their day, and an alarm when she was told a time; a
reminder you add to that list reaches her through `POST /api/agenda`; ticking
one off on either side ticks it off on the other (`POST /api/agenda/done`),
and deleting one from the phone counts as done. Events stay in Calendar. It
runs when the app comes to the front, on a background refresh, after a
tick-off in Status, and whenever Reminders reports a change while the app is
open. This has to live in the app: iCloud stopped exposing reminder lists over
CalDAV with the iOS 13 Reminders upgrade, so the server cannot write them.
`Services/Reminders.swift`; the id mapping lives in UserDefaults.

## What is not here yet

- **Real push notifications, until the APNs key is installed.** The server
  can send through Apple (`electron/apns.ts`, token auth, HTTP/2) and the app
  registers its token, but both are inert until `apns` is set in the server's
  config with the `.p8` key (see TestFlight above). Until then she relies on
  background refresh, which iOS runs on its own schedule — minutes to hours
  apart, and not at all in Low Power Mode.
- **The Live2D model.** Her animated model was tried on the stage and set
  aside: 29 MB over the tailnet and a web renderer on the phone for a face the
  SVG does in 30 KB. The stage plumbing (`haru-stage://`) would carry it again.
