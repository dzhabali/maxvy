#!/bin/bash
# Сборка и загрузка Ваджры в App Store Connect (TestFlight).
#   tools/upload.sh            (на Mac mini; ключ и подпись — в ~/.appstoreconnect, см. README)
# Ключ API: ~/.appstoreconnect/AuthKey_$ASC_KEY_ID.p8. Подпись ручная: сертификат Apple Distribution
# в отдельной связке shama-build.keychain (пароль ~/.appstoreconnect/signing/keychain-pass),
# профили «Vajra App Store» и «Vajra Widgets App Store» заданы по таргетам в project.yml (Release). Устройства в аккаунте не нужны.
# Номер сборки (CURRENT_PROJECT_VERSION в project.yml) увеличивается на 1 перед каждой загрузкой.
set -euo pipefail

TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$TOOLS/.."

ASC_KEY_ID="${ASC_KEY_ID:-GTFY4P5UPP}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-74224bd7-bbf9-4a2f-a400-0ed839c272bb}"
export PATH="/opt/homebrew/bin:$PATH"
KC="$HOME/Library/Keychains/shama-build.keychain-db"
security unlock-keychain -p "$(cat "$HOME/.appstoreconnect/signing/keychain-pass")" "$KC"
KEY_PATH="$HOME/.appstoreconnect/AuthKey_${ASC_KEY_ID}.p8"
[ -f "$KEY_PATH" ] || { echo "нет ключа $KEY_PATH" >&2; exit 1; }

# 1. build number +1
cur=$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"?([0-9]+)"?.*/\1/p' project.yml | head -1)
[ -n "$cur" ] || { echo "не нашёл CURRENT_PROJECT_VERSION в project.yml" >&2; exit 1; }
next=$((cur + 1))
sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*)\"?[0-9]+\"?/\1\"${next}\"/" project.yml
echo "build ${cur} → ${next}"

# 1б. версия +1 к младшей цифре: 1.0 → 1.1 → 1.2 — её видно в TestFlight. Своя: VERSION=2.0 tools/upload.sh
#     (не 1.01: Apple сравнивает числами, 1.01 = 1.1 и билд отклонит)
curv=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9]+\.[0-9]+)"?.*/\1/p' project.yml | head -1)
[ -n "$curv" ] || { echo "не нашёл MARKETING_VERSION в project.yml" >&2; exit 1; }
newv="${VERSION:-${curv%.*}.$(( ${curv#*.} + 1 ))}"
sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:[[:space:]]*)\"?[0-9.]+\"?/\1\"${newv}\"/" project.yml
echo "version ${curv} → ${newv}"

# 2. проект
xcodegen generate

AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")
# профили — по таргетам в project.yml (Release); здесь только связка ключей
SIGN=(OTHER_CODE_SIGN_FLAGS="--keychain $KC")

ARCHIVE="build/Vajra.xcarchive"
rm -rf "$ARCHIVE" build/export

# 3. archive
xcodebuild -project Vajra.xcodeproj -scheme Vajra -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  "${SIGN[@]}" archive

# 4. export + upload
# PATH без Homebrew: системный rsync запускает «rsync» по PATH, а brew-rsync 3.x не знает -E → «Copy failed»
env PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist tools/ExportOptions.plist -exportPath build/export \
  "${AUTH[@]}"

echo "загружено: v$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9.]+)"?.*/\1/p' project.yml | head -1) (${next})"

# 5. «Что нового» в TestFlight: NOTES="…" tools/upload.sh — фоном ждёт, пока Apple обработает билд, и ставит текст
if [ -n "${NOTES:-}" ]; then
  if python3 -c "import jwt" 2>/dev/null; then
    nohup python3 "$TOOLS/../../../shamatimer/ios/tools/asc.py" whats-new com.maxdzhabali.vajra "$next" "$NOTES" > build/whats-new.log 2>&1 &
    echo "«Что нового» — фоном (до 60 мин), лог build/whats-new.log"
  else
    echo "нет PyJWT — «Что нового» поставить с MacBook: asc.py whats-new com.maxdzhabali.vajra $next \"…\""
  fi
fi
