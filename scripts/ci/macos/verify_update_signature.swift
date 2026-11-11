import CryptoKit
import Foundation

// 检查 CI Secret 与应用内公钥配对，避免发布客户端无法验证的更新包。
guard CommandLine.arguments.count == 4,
      let publicKey = Data(base64Encoded: CommandLine.arguments[1]),
      let signature = Data(base64Encoded: CommandLine.arguments[2]) else {
  fputs("Expected public key, signature and archive path.\n", stderr)
  exit(1)
}

do {
  let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
  let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]),
                         options: .mappedIfSafe)
  guard key.isValidSignature(signature, for: archive) else {
    fputs("Sparkle signing key does not match the application public key.\n", stderr)
    exit(1)
  }
} catch {
  fputs("Unable to verify Sparkle update signature: \(error)\n", stderr)
  exit(1)
}
