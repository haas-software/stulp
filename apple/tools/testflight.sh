#!/bin/sh
# Archiveert Stulp (Release) en uploadt naar App Store Connect voor TestFlight, of exporteert alleen.
#   tools/testflight.sh [upload|export] [ios] [macos]
# Standaard upload van ios; macos alleen als je hem noemt, tot het app-record in App Store Connect
# ook macOS heeft. `export` ondertekent voor App Store Connect en schrijft de .ipa/.pkg naar
# build/testflight/<build>/ zonder te uploaden, om signing en profielen te controleren.
#
# Zoals bij haasdrive en lumen-apple: het buildnummer is de tijd, YYYYMMDD.HHMM, voor de app en zijn
# extensies tegelijk (CURRENT_PROJECT_VERSION op de commandoregel), en signing is automatisch met het
# Xcode-account op deze Mac (-allowProvisioningUpdates). Het app-record met bundle-id
# software.haas.stulp moet in App Store Connect bestaan.
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
cd "$(dirname "$0")/.."

MODE=${1:-upload}
case "$MODE" in upload|export) shift || true ;; *) MODE=upload ;; esac
PLATFORMS=${*:-ios}
BUILD=${BUILD:-$(date +%Y%m%d.%H%M)}
OUT=build/testflight/$BUILD
mkdir -p "$OUT"

xcodegen generate --quiet
OPTIONS="$OUT/ExportOptions.plist"
sed "s/@DESTINATION@/$MODE/" tools/ExportOptions-testflight.plist >"$OPTIONS"

for platform in $PLATFORMS; do
	case "$platform" in
	ios) destination="generic/platform=iOS" ;;
	macos) destination="generic/platform=macOS" ;;
	*) echo "testflight: onbekend platform $platform (ios, macos)" >&2; exit 2 ;;
	esac
	archive="$OUT/Stulp-$platform.xcarchive"
	echo "== Stulp $platform: archive, build $BUILD"
	xcodebuild -project Stulp.xcodeproj -scheme Stulp -configuration Release \
		-destination "$destination" -archivePath "$archive" \
		-derivedDataPath build/testflight/DerivedData \
		-allowProvisioningUpdates $AUTH CURRENT_PROJECT_VERSION="$BUILD" \
		archive -quiet
	echo "== Stulp $platform: $MODE"
	xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$OPTIONS" \
		-exportPath "$OUT/export-$platform" -allowProvisioningUpdates $AUTH
done
echo "testflight: Stulp $PLATFORMS build $BUILD ($MODE) in $OUT"
