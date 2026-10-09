"""Verify the signed archive has CarPlay registration and Apple's entitlement."""
import plistlib
import subprocess
import sys
from pathlib import Path

ENTITLEMENT = "com.apple.developer.carplay-voice-based-conversation"


def verify(app):
    info = plistlib.loads((app / "Info.plist").read_bytes())
    configs = info.get("UIApplicationSceneManifest", {}).get("UISceneConfigurations", {})
    scenes = configs.get("CPTemplateApplicationSceneSessionRoleApplication", [])
    if not any(scene.get("UISceneClassName") == "CPTemplateApplicationScene"
               and scene.get("UISceneDelegateClassName", "").endswith(".HaruCarPlayScene")
               for scene in scenes):
        raise RuntimeError("The built app has no Haru CarPlay scene registration.")
    signed = subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", str(app)],
        check=True, capture_output=True,
    )
    entitlements = plistlib.loads(signed.stdout)
    if entitlements.get(ENTITLEMENT) is not True:
        raise RuntimeError("The app signature lacks the CarPlay conversation entitlement.")
    profile = subprocess.run(
        ["security", "cms", "-D", "-i", str(app / "embedded.mobileprovision")],
        check=True, capture_output=True,
    )
    provision = plistlib.loads(profile.stdout)
    if provision.get("Entitlements", {}).get(ENTITLEMENT) is not True:
        raise RuntimeError("Apple's provisioning profile lacks the approved CarPlay entitlement.")
    print("CarPlay scene registration, signed entitlement and Apple provisioning profile verified.")


if __name__ == "__main__":
    try:
        verify(Path(sys.argv[1]))
    except (IndexError, OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"CarPlay signing verification failed: {error}", file=sys.stderr)
        sys.exit(1)
