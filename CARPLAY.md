# Haru in CarPlay

Built with the iOS 27 SDK. The ordinary iPhone app keeps its existing deployment target.
CarPlay shares the phone's account, conversation, voice transport and enabled phone tools.
This release includes the server conversation and retired model cleanup from build 142;
no on-device conversation model is restored by the CarPlay integration.

## Before the first drive

1. Apple has confirmed account eligibility for the **voice-based conversational**
   CarPlay entitlement. Enable it for the existing
   `com.toomiiverse.haru.JF3928RYMD` App ID at https://developer.apple.com/carplay/.
   The required key is `com.apple.developer.carplay-voice-based-conversation`.
   Adding the key to the source does not grant approval. Enable the approved managed
   capability on that App ID before requesting a signed TestFlight build.
2. On the phone, sign in, connect Tailscale, and verify an ordinary Haru voice call.
   Allow microphone access there, before driving.
3. In More → Phone tools, enable the desired weather, reminders, location and maps
   tools. Grant any requested permissions while parked. Navigation preparation needs
   Maps and Location; unavailable briefing data is skipped, never invented.
4. In Shortcuts → Automation → CarPlay → Connects, select Run Immediately and
   add Open App → Haru. Enable CarPlay while locked for your car in iPhone settings.
   Automation does not guarantee iOS will foreground the CarPlay scene. If it doesn't,
   tap Haru's CarPlay icon. No background launch or locked-phone microphone bypass is used.

## In the car

Opening Haru goes straight into the existing voice call, like answering a phone:
the car screen shows Listening once her line answers and her server greets you.
The spoken briefing that used to run first was removed (it kept the car on
Connecting with no sound). Since server 4720 her brain reads the car screen state
off the phone's heartbeat and, while the car is in a conversation, every call turn
tells her you are driving on the car speakers: short replies, no screen, and the
maps tool when you ask for directions. Since server 4740 her voice filter admits
call turns unscored while the car screen is in a conversation, so anyone in the
car can talk to her; End conversation is the guard. Reopening the scene in the
same connection resumes the conversation. The car screen shows her face for Talk,
Connecting, Listening, Thinking and Speaking (one picture each, from her look); the
failure states keep their symbols. Only the idle states carry the Talk button on the card;
while she is in a conversation, End conversation sits in the bar's leading corner and
Navigate in its trailing corner, so her picture gets the card.

Ask for driving directions. Haru searches nearby using MapKit, returns ambiguity to
her existing tools when several places match, and calculates an estimated travel time
for one resolved destination. Tap **Navigate** to open Apple Maps on the car display.
A prepared route isn't a claim that navigation has started. Routes expire after five
minutes and are cleared on disconnection.

**End conversation** releases the microphone and audio session. Leaving Haru's
CarPlay screen, including opening Maps, pauses the voice session. Tap Haru to talk
again. Phone calls and Siri also interrupt it; recording doesn't restart silently.
The phone's wake-word standby preference is retained, but standby is suspended in
CarPlay. Haru never displays chat transcripts or generated pictures in the car.
On iOS 27 the voice card sits on a dark plum backdrop lit in her accent; older phones show the plain card.

## Building and verification

The `iOS` workflow uses GitHub's `xcode-27` runner and checks the SDK version.
Manual runs default to an unsigned build, which can compile without the managed
entitlement approval. Enable `upload_to_testflight` only after Apple has approved it.
An unsigned IPA is a build artifact, not an installable signed CarPlay app.

Run `bash scripts/test-drive.sh` for the connection lifecycle and Maps URL checks.
`scripts/carplay-preview.sh` draws the voice card as CarPlay renders it, every state at three
car sizes in both appearances, with no car (a commit message line `Haru-CarPlay-Preview: true`
makes CI do it and keep the pictures as the carplay-preview artifact).
The existing transport, chat-delivery, stage recovery and retired model cleanup tests
also run in CI. Signed archives additionally verify the compiled scene registration,
app signature and Apple's provisioning profile contain the approved entitlement.
On a real iPhone/car,
verify cold and warm launch, locked-phone launch, repeated scene activation, denied
microphone permission, Tailscale loss, sign-out, interrupted calls, missing tool
permissions, ambiguous destinations, rejected Maps handoff, and disconnect during
the briefing. Confirm music resumes after End and that ordinary phone calls, chat,
attachments and standby still work outside CarPlay.

No vehicle control or custom turn-by-turn navigation is included. Traffic estimates
come from MapKit; guidance belongs to Apple Maps.
