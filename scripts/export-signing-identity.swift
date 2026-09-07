import Foundation
import Security
import CryptoKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
// The wrapping password arrives over stdin, never in command arguments or files.
guard CommandLine.arguments.count == 2, let password = readLine(), password.count >= 32 else {
    fail("Expected certificate SHA-1 and a strong wrapping password on stdin.")
}
let fingerprint = CommandLine.arguments[1].uppercased()
var result: CFTypeRef?
let status = SecItemCopyMatching([
    kSecClass as String: kSecClassIdentity,
    kSecReturnRef as String: true,
    kSecMatchLimit as String: kSecMatchLimitAll
] as CFDictionary, &result)
guard status == errSecSuccess, let identities = result as? [SecIdentity] else {
    fail("Cannot access signing identities (OSStatus \(status)).")
}
let matches = identities.filter { identity in
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return false }
    let hash = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
        .map { String(format: "%02X", $0) }.joined()
    return hash == fingerprint
}
guard matches.count == 1 else { fail("The exact requested signing identity was not found.") }
var parameters = SecItemImportExportKeyParameters()
parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
parameters.passphrase = Unmanaged.passRetained(password as CFString)
defer { parameters.passphrase?.release() }
var exported: CFData?
let exportStatus = SecItemExport(matches[0], .formatPKCS12, [], &parameters, &exported)
guard exportStatus == errSecSuccess, let exported else { fail("Identity export failed (OSStatus \(exportStatus)).") }
// Binary output is consumed only by the setup process, never printed to the terminal.
FileHandle.standardOutput.write(exported as Data)
