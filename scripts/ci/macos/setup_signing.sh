#!/usr/bin/env bash
set -euo pipefail
umask 077

# SwiftPM 下载二进制依赖会查询钥匙串。CI 仅搜索已解锁的临时钥匙串，
# 避免 runner 的 login 钥匙串触发不可见的授权窗口。无证书构建同样需要隔离。
: "${RUNNER_TEMP:?需要 GitHub Actions 的临时目录}"
P12_BASE64="${P12_BASE64:-}"
P12_PASSWORD="${P12_PASSWORD:-}"

KEYCHAIN_PATH="$RUNNER_TEMP/build.keychain-db"
KEYCHAIN_PASSWORD=$(openssl rand -base64 24)
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security list-keychains -d user -s "$KEYCHAIN_PATH"
security default-keychain -s "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"

if [ -z "$P12_BASE64" ]; then
  echo "MACOS_CODESIGN_P12_BASE64 未配置,回退 adhoc 签名"
  exit 0
fi

echo "$P12_BASE64" | base64 -d > "$RUNNER_TEMP/codesign.p12"
security import "$RUNNER_TEMP/codesign.p12" -k "$KEYCHAIN_PATH" \
  -P "$P12_PASSWORD" -T /usr/bin/codesign
# 允许 codesign 免交互使用私钥(CI 无 GUI,不设置会卡死在授权弹窗)
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" > /dev/null
# 自签证书需要显式授信 codeSign 策略,identity 才会被视为有效
openssl pkcs12 -in "$RUNNER_TEMP/codesign.p12" -passin "pass:$P12_PASSWORD" \
  -nokeys -legacy -clcerts | openssl x509 -out "$RUNNER_TEMP/codesign.cer" -outform DER
sudo security add-trusted-cert -d -p codeSign -r trustRoot \
  -k /Library/Keychains/System.keychain "$RUNNER_TEMP/codesign.cer"
rm -f "$RUNNER_TEMP/codesign.p12"
security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep -q "FluxDO Code Signing"
# 通过 Local.xcconfig 覆盖签名身份(与本地开发同一机制)
printf '%s\n' \
  'FLUXDO_APPLE_CODE_SIGN_IDENTITY_MACOSX = FluxDO Code Signing' \
  'FLUXDO_APPLE_CODE_SIGN_STYLE = Manual' \
  'FLUXDO_APPLE_CODE_SIGNING_ALLOWED = YES' > apple/Local.xcconfig
