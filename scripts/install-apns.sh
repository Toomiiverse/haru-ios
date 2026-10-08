#!/usr/bin/env bash
# Run on the server once the APNs key exists. Puts the .p8 where the server
# reads it and adds the apns block to config.json (stop → backup → edit → start,
# since the running app rewrites config.json on its own).
#
#   scripts/install-apns.sh ~/AuthKey_5T6M2M2859.p8 5T6M2M2859 JF3928RYMD
#
# The key comes from developer.apple.com → Certificates, Identifiers & Profiles
# → Keys → "+" with Apple Push Notifications service (APNs) ticked. This is a
# different key from the App Store Connect API one.
set -euo pipefail
p8=${1:?path to the APNs .p8}
key_id=${2:?Key ID}
team=${3:?Team ID}
cfg_dir=~/.config/haru-desktop
cfg=$cfg_dir/config.json
dest=$cfg_dir/apns.p8
grep -q "BEGIN PRIVATE KEY" "$p8" || { echo "$p8 does not look like a .p8 key" >&2; exit 1; }

install -m 600 "$p8" "$dest"
systemctl --user stop haru.service
stamp=$(date -u +%Y-%m-%dT%H-%M-%SZ)
cp "$cfg" "$cfg.before-apns-$stamp"
node - "$cfg" "$dest" "$key_id" "$team" <<'JS'
const fs = require('fs');
const [cfg, keyPath, keyId, teamId] = process.argv.slice(2);
const c = JSON.parse(fs.readFileSync(cfg, 'utf8'));
c.apns = { ...(c.apns || {}), keyPath, keyId, teamId, bundleId: 'com.toomiiverse.haru.JF3928RYMD' };
fs.writeFileSync(cfg, JSON.stringify(c, null, 2));
console.log('apns =', JSON.stringify({ ...c.apns, devices: undefined }));
JS
systemctl --user start haru.service
echo "Backup: $cfg.before-apns-$stamp"
echo "Now open the TestFlight build on the phone; it registers its token at /api/push/apns and shows up under apns.devices."
