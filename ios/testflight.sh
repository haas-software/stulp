#!/bin/sh
# Archiveert Stulp (Release) en uploadt naar App Store Connect voor TestFlight, of exporteert alleen.
#   ./testflight.sh [upload|export]
# Standaard upload. `export` ondertekent voor App Store Connect en schrijft de .ipa naar
# build/testflight/<build>/ zonder te uploaden, om signing en profielen te controleren.
#
# Zoals bij haasdrive en lumen-apple: het buildnummer is de tijd, YYYYMMDD.HHMM, voor app en
# Matter-extensie tegelijk (CURRENT_PROJECT_VERSION op de commandoregel), en signing is automatisch
# met het Xcode-account op deze Mac (-allowProvisioningUpdates), zonder App Store Connect-sleutel.
# Het app-record met bundle-id software.haas.stulp moet in App Store Connect bestaan.
set -eu
# App Store Connect API key, if present: signing, export and upload then need no Xcode account on
# this Mac. ASC_ENV points at a file with ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (outside every
# repository; default ~/Git/haas.software/AUTH/appstoreconnect.env).
ASC_ENV=${ASC_ENV:-$HOME/Git/haas.software/AUTH/appstoreconnect.env}
AUTH=
if [ -f "$ASC_ENV" ]; then
	. "$ASC_ENV"
	AUTH="-authenticationKeyPath $ASC_KEY_PATH -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"
fi
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

MODE=${1:-upload}
case "$MODE" in upload|export) ;; *) echo "testflight: upload of export" >&2; exit 2 ;; esac
BUILD=${BUILD:-$(date +%Y%m%d.%H%M)}
OUT=build/testflight/$BUILD
mkdir -p "$OUT"

xcodegen generate --quiet
sed "s/@DESTINATION@/$MODE/" ExportOptions-testflight.plist >"$OUT/ExportOptions.plist"

echo "== Stulp: archive, build $BUILD"
xcodebuild -project Stulp.xcodeproj -scheme Stulp -configuration Release \
	-destination 'generic/platform=iOS' -archivePath "$OUT/Stulp.xcarchive" \
	-derivedDataPath build/testflight/DerivedData \
	-allowProvisioningUpdates $AUTH CURRENT_PROJECT_VERSION="$BUILD" \
	archive -quiet
echo "== Stulp: $MODE"
xcodebuild -exportArchive -archivePath "$OUT/Stulp.xcarchive" \
	-exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" \
	-allowProvisioningUpdates $AUTH
echo "testflight: Stulp build $BUILD ($MODE) in $OUT"
