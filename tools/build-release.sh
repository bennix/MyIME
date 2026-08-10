#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PROJECT="$ROOT_DIR/MyIME/MyIME.xcodeproj"
PLIST="$ROOT_DIR/MyIME/MyIME/Resources/Info.plist"
DATABASE="$ROOT_DIR/MyIME/MyIME/Resources/system.sqlite"
OUTPUT_DIR=${MYIME_OUTPUT_DIR:-"$ROOT_DIR/dist"}
ALLOW_ADHOC=${MYIME_ALLOW_ADHOC:-0}
ALLOW_DEVELOPMENT=${MYIME_ALLOW_DEVELOPMENT:-0}
SIGNING_IDENTITY=${MYIME_SIGNING_IDENTITY:-}
NOTARY_PROFILE=${MYIME_NOTARY_PROFILE:-}

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/MyIME-release.XXXXXX")
trap '/bin/rm -rf "$WORK_DIR"' EXIT HUP INT TERM

find_identity() {
    identity=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
        | head -n 1)
    printf '%s' "$identity"
}

if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY=$(find_identity)
fi

case "$SIGNING_IDENTITY" in
    "Developer ID Application:"*) SIGNATURE_LABEL="developer-id" ;;
    "Apple Development:"*)
        if [ "$ALLOW_DEVELOPMENT" != "1" ]; then
            echo "error: Apple Development signatures are not valid for public distribution." >&2
            echo "Use Developer ID Application, or set MYIME_ALLOW_DEVELOPMENT=1 for a registered test Mac only." >&2
            exit 2
        fi
        SIGNATURE_LABEL="apple-development"
        ;;
    "") SIGNATURE_LABEL="local-adhoc" ;;
    *) SIGNATURE_LABEL="signed" ;;
esac
ARTIFACT_SUFFIX=""
if [ -z "$SIGNING_IDENTITY" ]; then
    if [ "$ALLOW_ADHOC" != "1" ]; then
        echo "error: no usable Apple code-signing identity is available." >&2
        echo "Install/import the certificate private key, or set MYIME_ALLOW_ADHOC=1 for a local test build." >&2
        exit 2
    fi
    ARTIFACT_SUFFIX="-local-adhoc"
elif [ "$SIGNATURE_LABEL" = "apple-development" ]; then
    ARTIFACT_SUFFIX="-development"
elif [ "$SIGNATURE_LABEL" != "developer-id" ]; then
    ARTIFACT_SUFFIX="-signed"
fi

if [ "$SIGNATURE_LABEL" = "developer-id" ] && [ -z "$NOTARY_PROFILE" ]; then
    echo "error: public distribution requires Apple notarization." >&2
    echo "Set MYIME_NOTARY_PROFILE to a notarytool keychain profile." >&2
    exit 2
fi

echo "==> Testing IME engine"
# The bundled-dictionary performance checks share the same SQLite resource.
# Swift Testing otherwise runs them concurrently and turns host load into a flaky P95 failure.
swift test --package-path "$ROOT_DIR/MyIME/IMEKit" --no-parallel

echo "==> Verifying bundled dictionary"
python3 "$SCRIPT_DIR/verify.py" "$DATABASE"

echo "==> Building MyIME $VERSION ($BUILD)"
xcodebuild \
    -project "$PROJECT" \
    -scheme MyIME \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$WORK_DIR/DerivedData" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

BUILT_APP="$WORK_DIR/DerivedData/Build/Products/Release/MyIME.app"
if [ ! -d "$BUILT_APP" ]; then
    echo "error: Xcode did not produce MyIME.app" >&2
    exit 3
fi

BUILT_ARCHS=$(lipo -archs "$BUILT_APP/Contents/MacOS/MyIME")
case " $BUILT_ARCHS " in *" arm64 "*) ;; *)
    echo "error: release is missing arm64: $BUILT_ARCHS" >&2
    exit 3
esac
case " $BUILT_ARCHS " in *" x86_64 "*) ;; *)
    echo "error: release is missing x86_64: $BUILT_ARCHS" >&2
    exit 3
esac

if [ -n "$SIGNING_IDENTITY" ]; then
    echo "==> Signing with $SIGNING_IDENTITY"
    codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$BUILT_APP"
else
    echo "==> Applying ad-hoc signature (local testing only)"
    codesign --force --deep --sign - "$BUILT_APP"
fi
codesign --verify --deep --strict --verbose=2 "$BUILT_APP"

MINIMUM_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$BUILT_APP/Contents/Info.plist")
if [ "$MINIMUM_OS" != "13.0" ]; then
    echo "error: unexpected minimum macOS version in release: $MINIMUM_OS" >&2
    exit 3
fi

mkdir -p "$OUTPUT_DIR"
APP_NAME="MyIME-$VERSION$ARTIFACT_SUFFIX.app"
DMG_NAME="MyIME-$VERSION$ARTIFACT_SUFFIX.dmg"
APP_OUTPUT="$OUTPUT_DIR/$APP_NAME"
DMG_OUTPUT="$OUTPUT_DIR/$DMG_NAME"
STAGE_DIR="$WORK_DIR/dmg"
mkdir -p "$STAGE_DIR"

case "$APP_OUTPUT" in
    "$OUTPUT_DIR"/MyIME-*.app) /bin/rm -rf "$APP_OUTPUT" ;;
    *) echo "error: refusing unsafe output path: $APP_OUTPUT" >&2; exit 4 ;;
esac
/usr/bin/ditto "$BUILT_APP" "$APP_OUTPUT"
/usr/bin/ditto "$BUILT_APP" "$STAGE_DIR/MyIME.app"
/usr/bin/ditto "$ROOT_DIR/release/安装说明.txt" "$STAGE_DIR/安装说明.txt"

if [ -e "$DMG_OUTPUT" ]; then
    case "$DMG_OUTPUT" in
        "$OUTPUT_DIR"/MyIME-*.dmg) /bin/rm -f "$DMG_OUTPUT" ;;
        *) echo "error: refusing unsafe output path: $DMG_OUTPUT" >&2; exit 4 ;;
    esac
fi

echo "==> Creating $DMG_NAME"
hdiutil create \
    -volname "MyIME $VERSION" \
    -srcfolder "$STAGE_DIR" \
    -format UDZO \
    -ov \
    "$DMG_OUTPUT"

if [ -n "$NOTARY_PROFILE" ]; then
    if [ "$SIGNATURE_LABEL" != "developer-id" ]; then
        echo "error: notarization requires a Developer ID Application signature" >&2
        exit 5
    fi
    echo "==> Notarizing and stapling DMG"
    xcrun notarytool submit "$DMG_OUTPUT" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_OUTPUT"
    xcrun stapler validate "$DMG_OUTPUT"
fi

(cd "$OUTPUT_DIR" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")

echo ""
echo "Created:"
echo "  $APP_OUTPUT"
echo "  $DMG_OUTPUT"
echo "  $DMG_OUTPUT.sha256"
echo "Signature: $SIGNATURE_LABEL"
