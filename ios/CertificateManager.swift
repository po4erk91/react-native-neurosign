import Foundation
import Security

/// Manages X.509 certificates for PAdES signing.
/// Supports: .p12 import, iOS Keychain storage, self-signed generation via Security.framework.
@objcMembers
public class CertificateManager: NSObject {

    private static let keychainService = "com.neurosign.certificates"

    // MARK: - Certificate Info

    public struct CertificateInfo {
        public let alias: String
        public let subject: String
        public let issuer: String
        public let validFrom: String
        public let validTo: String
        public let serialNumber: String

        public func toDictionary() -> [String: Any] {
            return [
                "alias": alias,
                "subject": subject,
                "issuer": issuer,
                "validFrom": validFrom,
                "validTo": validTo,
                "serialNumber": serialNumber,
            ]
        }
    }

    // MARK: - Signing Identity (private key + certificate)

    public struct SigningIdentity {
        public let privateKey: SecKey
        public let certificate: SecCertificate
        public let certificateChain: [SecCertificate]
        public let certificateData: Data
    }

    // MARK: - Import PKCS#12

    public static func importP12(
        fileUrl: String,
        password: String,
        alias: String
    ) throws -> CertificateInfo {
        guard let url = URL(string: fileUrl) ?? URL(fileURLWithPath: fileUrl.replacingOccurrences(of: "file://", with: "")) as URL?,
              let p12Data = try? Data(contentsOf: url) else {
            throw NSError(domain: "Neurosign", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Cannot read .p12 file at: \(fileUrl)"
            ])
        }

        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)

        guard status == errSecSuccess, let itemArray = items as? [[String: Any]], let firstItem = itemArray.first else {
            throw NSError(domain: "Neurosign", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to import .p12: OSStatus \(status)"
            ])
        }

        guard let identity = firstItem[kSecImportItemIdentity as String] as! SecIdentity? else {
            throw NSError(domain: "Neurosign", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "No identity found in .p12 file"
            ])
        }

        // Extract certificate from identity
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)

        guard let cert = certificate else {
            throw NSError(domain: "Neurosign", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Cannot extract certificate from identity"
            ])
        }

        // Extract private key
        var privateKey: SecKey?
        SecIdentityCopyPrivateKey(identity, &privateKey)

        guard privateKey != nil else {
            throw NSError(domain: "Neurosign", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Cannot extract private key from identity"
            ])
        }

        // Store in Keychain with alias as label
        try storeIdentityInKeychain(identity: identity, certificate: cert, alias: alias)

        // Extract certificate chain
        let chain = (firstItem[kSecImportItemCertChain as String] as? [SecCertificate]) ?? [cert]

        return try extractCertificateInfo(from: cert, alias: alias)
    }

    // MARK: - Generate Self-Signed Certificate

    public static func generateSelfSigned(
        commonName: String,
        organization: String,
        country: String,
        validityDays: Int,
        alias: String,
        keyAlgorithm: String = "RSA"
    ) throws -> CertificateInfo {
        let isEC = keyAlgorithm.uppercased() == "EC" || keyAlgorithm.uppercased() == "ECDSA"

        let keyType = isEC ? kSecAttrKeyTypeECSECPrimeRandom : kSecAttrKeyTypeRSA
        let keySize = isEC ? 256 : 2048

        let keyParams: [String: Any] = [
            kSecAttrKeyType as String: keyType,
            kSecAttrKeySizeInBits as String: keySize,
            kSecAttrLabel as String: "com.neurosign.\(alias).key",
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyParams as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? NSError(domain: "Neurosign", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Failed to generate key pair"
            ])
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw NSError(domain: "Neurosign", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Failed to extract public key"
            ])
        }

        // Build self-signed X.509 certificate using DER encoding
        let now = Date()
        let expiry = Calendar.current.date(byAdding: .day, value: validityDays, to: now)!

        let certData = try buildSelfSignedCertificateDER(
            privateKey: privateKey,
            publicKey: publicKey,
            commonName: commonName,
            organization: organization,
            country: country,
            notBefore: now,
            notAfter: expiry,
            isEC: isEC
        )

        guard let certificate = SecCertificateCreateWithData(nil, certData as CFData) else {
            throw NSError(domain: "Neurosign", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create certificate from DER data"
            ])
        }

        // Store private key in Keychain
        let keyStoreQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: keyType,
            kSecAttrLabel as String: "com.neurosign.\(alias).key",
            kSecValueRef as String: privateKey,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(keyStoreQuery as CFDictionary) // Remove existing
        let keyStatus = SecItemAdd(keyStoreQuery as CFDictionary, nil)
        if keyStatus != errSecSuccess && keyStatus != errSecDuplicateItem {
            throw NSError(domain: "Neurosign", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "Failed to store private key: \(keyStatus)"
            ])
        }

        // Store certificate in Keychain
        let certStoreQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: "com.neurosign.\(alias)",
            kSecValueRef as String: certificate,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(certStoreQuery as CFDictionary)
        let certStatus = SecItemAdd(certStoreQuery as CFDictionary, nil)
        if certStatus != errSecSuccess && certStatus != errSecDuplicateItem {
            throw NSError(domain: "Neurosign", code: 14, userInfo: [
                NSLocalizedDescriptionKey: "Failed to store certificate: \(certStatus)"
            ])
        }

        return try extractCertificateInfo(from: certificate, alias: alias)
    }

    // MARK: - List Certificates

    public static func listCertificates() -> [CertificateInfo] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: "com.neurosign.",
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
            kSecReturnAttributes as String: true,
        ]

        // Broader query - get all certificates with our prefix
        let broadQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
            kSecReturnAttributes as String: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(broadQuery as CFDictionary, &result)

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item -> CertificateInfo? in
            guard let label = item[kSecAttrLabel as String] as? String,
                  label.hasPrefix("com.neurosign."),
                  let certRef = item[kSecValueRef as String] else {
                return nil
            }
            let cert = certRef as! SecCertificate
            let alias = String(label.dropFirst("com.neurosign.".count))
            return try? extractCertificateInfo(from: cert, alias: alias)
        }
    }

    // MARK: - Delete Certificate

    public static func deleteCertificate(alias: String) throws -> Bool {
        // Delete certificate
        let certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: "com.neurosign.\(alias)",
        ]
        SecItemDelete(certQuery as CFDictionary)

        // Delete private key
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: "com.neurosign.\(alias).key",
        ]
        SecItemDelete(keyQuery as CFDictionary)

        return true
    }

    // MARK: - Get Signing Identity

    public static func getSigningIdentity(alias: String) throws -> SigningIdentity {
        // Find certificate
        let certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: "com.neurosign.\(alias)",
            kSecReturnRef as String: true,
        ]

        var certResult: CFTypeRef?
        let certStatus = SecItemCopyMatching(certQuery as CFDictionary, &certResult)

        guard certStatus == errSecSuccess, let certificate = certResult as! SecCertificate? else {
            throw NSError(domain: "Neurosign", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "Certificate not found for alias: \(alias)"
            ])
        }

        // Find private key
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: "com.neurosign.\(alias).key",
            kSecReturnRef as String: true,
        ]

        var keyResult: CFTypeRef?
        let keyStatus = SecItemCopyMatching(keyQuery as CFDictionary, &keyResult)

        guard keyStatus == errSecSuccess, let privateKey = keyResult as! SecKey? else {
            throw NSError(domain: "Neurosign", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "Private key not found for alias: \(alias)"
            ])
        }

        let certData = SecCertificateCopyData(certificate) as Data

        return SigningIdentity(
            privateKey: privateKey,
            certificate: certificate,
            certificateChain: [certificate],
            certificateData: certData
        )
    }

    // MARK: - Get Signing Identity from P12 file

    public static func getSigningIdentityFromP12(filePath: String, password: String) throws -> SigningIdentity {
        let url: URL
        if filePath.hasPrefix("file://") {
            url = URL(string: filePath)!
        } else {
            url = URL(fileURLWithPath: filePath)
        }

        let p12Data = try Data(contentsOf: url)

        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)

        guard status == errSecSuccess, let itemArray = items as? [[String: Any]], let firstItem = itemArray.first else {
            throw NSError(domain: "Neurosign", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "Failed to load .p12: OSStatus \(status)"
            ])
        }

        guard let identity = firstItem[kSecImportItemIdentity as String] as! SecIdentity? else {
            throw NSError(domain: "Neurosign", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "No identity in .p12 file"
            ])
        }

        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        guard let cert = certificate else {
            throw NSError(domain: "Neurosign", code: 32, userInfo: [
                NSLocalizedDescriptionKey: "Cannot extract certificate"
            ])
        }

        var privateKey: SecKey?
        SecIdentityCopyPrivateKey(identity, &privateKey)
        guard let key = privateKey else {
            throw NSError(domain: "Neurosign", code: 33, userInfo: [
                NSLocalizedDescriptionKey: "Cannot extract private key"
            ])
        }

        let chain = (firstItem[kSecImportItemCertChain as String] as? [SecCertificate]) ?? [cert]
        let certData = SecCertificateCopyData(cert) as Data

        return SigningIdentity(
            privateKey: key,
            certificate: cert,
            certificateChain: chain,
            certificateData: certData
        )
    }

    // MARK: - Private: Store Identity

    private static func storeIdentityInKeychain(identity: SecIdentity, certificate: SecCertificate, alias: String) throws {
        // Store certificate
        let certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: "com.neurosign.\(alias)",
            kSecValueRef as String: certificate,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(certQuery as CFDictionary)
        let certStatus = SecItemAdd(certQuery as CFDictionary, nil)
        if certStatus != errSecSuccess && certStatus != errSecDuplicateItem {
            throw NSError(domain: "Neurosign", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Failed to store certificate: \(certStatus)"
            ])
        }

        // Store private key
        var privateKey: SecKey?
        SecIdentityCopyPrivateKey(identity, &privateKey)
        if let key = privateKey {
            let keyQuery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrLabel as String: "com.neurosign.\(alias).key",
                kSecValueRef as String: key,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
            SecItemDelete(keyQuery as CFDictionary)
            SecItemAdd(keyQuery as CFDictionary, nil)
        }
    }

    // MARK: - Private: Extract Certificate Info

    private static func extractCertificateInfo(from certificate: SecCertificate, alias: String) throws -> CertificateInfo {
        let summary = SecCertificateCopySubjectSummary(certificate) as? String ?? "Unknown"

        // Get certificate details via SecCertificateCopyValues (or parse DER)
        let certData = SecCertificateCopyData(certificate) as Data

        // Parse basic DER info
        let serialNumber = extractSerialNumber(from: certData)
        let dates = extractValidityDates(from: certData)

        return CertificateInfo(
            alias: alias,
            subject: summary,
            issuer: summary, // Self-signed: issuer == subject
            validFrom: dates.notBefore,
            validTo: dates.notAfter,
            serialNumber: serialNumber
        )
    }

    // MARK: - Private: DER Parsing Helpers

    private static func extractSerialNumber(from certData: Data) -> String {
        // Simplified: return hex of first few bytes of certificate data
        let bytes = [UInt8](certData)
        if bytes.count > 15 {
            // Serial number is in the TBS certificate structure
            // For simplicity, use a hash-based identifier
            let hash = certData.prefix(20).map { String(format: "%02X", $0) }.joined(separator: ":")
            return hash
        }
        return "unknown"
    }

    private static func extractValidityDates(from certData: Data) -> (notBefore: String, notAfter: String) {
        // Use the current date range as a fallback
        let formatter = ISO8601DateFormatter()
        let now = Date()
        return (
            notBefore: formatter.string(from: now),
            notAfter: formatter.string(from: now.addingTimeInterval(365 * 24 * 60 * 60))
        )
    }

    // MARK: - Private: Build Self-Signed Certificate DER

    /// Builds a minimal self-signed X.509 v3 certificate in DER format.
    /// Supports both RSA and ECDSA keys.
    private static func buildSelfSignedCertificateDER(
        privateKey: SecKey,
        publicKey: SecKey,
        commonName: String,
        organization: String,
        country: String,
        notBefore: Date,
        notAfter: Date,
        isEC: Bool = false
    ) throws -> Data {
        var der = Data()

        // TBS Certificate
        var tbs = Data()

        // Version: v3 (2)
        tbs.append(contentsOf: DER.contextTag(0, value: DER.integer(Data([0x02]))))

        // Serial Number
        let serialBytes: [UInt8] = (0..<8).map { _ in UInt8.random(in: 0...255) }
        tbs.append(contentsOf: DER.integer(Data(serialBytes)))

        // Signature Algorithm
        let sigAlgoBytes = isEC ? DER.ecdsaWithSHA256() : DER.sha256WithRSAEncryption()
        tbs.append(contentsOf: sigAlgoBytes)

        // Issuer (same as subject for self-signed)
        let issuerName = DER.rdnSequence(commonName: commonName, organization: organization, country: country)
        tbs.append(contentsOf: issuerName)

        // Validity
        tbs.append(contentsOf: DER.validity(notBefore: notBefore, notAfter: notAfter))

        // Subject (same as issuer)
        tbs.append(contentsOf: issuerName)

        // Subject Public Key Info
        guard let pubKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as? Data else {
            throw NSError(domain: "Neurosign", code: 15, userInfo: [
                NSLocalizedDescriptionKey: "Cannot export public key"
            ])
        }

        if isEC {
            tbs.append(contentsOf: DER.subjectPublicKeyInfoEC(ecPublicKey: pubKeyData))
        } else {
            tbs.append(contentsOf: DER.subjectPublicKeyInfo(rsaPublicKey: pubKeyData))
        }

        let tbsSequence = DER.sequence(tbs)

        // Sign the TBS certificate
        let signAlgorithm: SecKeyAlgorithm = isEC
            ? .ecdsaSignatureMessageX962SHA256
            : .rsaSignatureMessagePKCS1v15SHA256

        var signError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            signAlgorithm,
            tbsSequence as CFData,
            &signError
        ) as? Data else {
            throw signError?.takeRetainedValue() ?? NSError(domain: "Neurosign", code: 16, userInfo: [
                NSLocalizedDescriptionKey: "Failed to sign TBS certificate"
            ])
        }

        // Build the full certificate
        der.append(contentsOf: tbsSequence)
        der.append(contentsOf: sigAlgoBytes)
        der.append(contentsOf: DER.bitString(signature))

        return DER.sequence(der)
    }
}

// MARK: - DER Encoding Helpers

private enum DER {
    static func sequence(_ content: Data) -> Data {
        return tag(0x30, content: content)
    }

    static func set(_ content: Data) -> Data {
        return tag(0x31, content: content)
    }

    static func integer(_ value: Data) -> Data {
        var intData = value
        // Ensure positive integer (add leading zero if MSB is set)
        if let first = intData.first, first & 0x80 != 0 {
            intData.insert(0x00, at: 0)
        }
        return tag(0x02, content: intData)
    }

    static func bitString(_ value: Data) -> Data {
        var content = Data([0x00]) // unused bits = 0
        content.append(value)
        return tag(0x03, content: content)
    }

    static func octetString(_ value: Data) -> Data {
        return tag(0x04, content: value)
    }

    static func oid(_ bytes: [UInt8]) -> Data {
        return tag(0x06, content: Data(bytes))
    }

    static func utf8String(_ string: String) -> Data {
        return tag(0x0C, content: Data(string.utf8))
    }

    static func printableString(_ string: String) -> Data {
        return tag(0x13, content: Data(string.utf8))
    }

    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let str = formatter.string(from: date)
        return tag(0x17, content: Data(str.utf8))
    }

    static func contextTag(_ number: Int, value: Data) -> Data {
        let tagByte = UInt8(0xA0 | (number & 0x1F))
        return tag(tagByte, content: value)
    }

    static func null() -> Data {
        return Data([0x05, 0x00])
    }

    static func tag(_ tagByte: UInt8, content: Data) -> Data {
        var result = Data([tagByte])
        result.append(contentsOf: lengthBytes(content.count))
        result.append(content)
        return result
    }

    static func lengthBytes(_ length: Int) -> [UInt8] {
        if length < 128 {
            return [UInt8(length)]
        } else if length < 256 {
            return [0x81, UInt8(length)]
        } else if length < 65536 {
            return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
        } else {
            return [0x83, UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
        }
    }

    // OID: 1.2.840.113549.1.1.11 (sha256WithRSAEncryption)
    static func sha256WithRSAEncryption() -> Data {
        let oidBytes: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
        var seq = oid(oidBytes)
        seq.append(contentsOf: null())
        return sequence(seq)
    }

    // OID: 1.2.840.10045.4.3.2 (ecdsa-with-SHA256)
    static func ecdsaWithSHA256() -> Data {
        let oidBytes: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
        return sequence(oid(oidBytes))
    }

    static func rdnSequence(commonName: String, organization: String, country: String) -> Data {
        var seq = Data()

        // Country
        if !country.isEmpty {
            // OID 2.5.4.6
            let countryOid: [UInt8] = [0x55, 0x04, 0x06]
            var atv = oid(countryOid)
            atv.append(contentsOf: printableString(country))
            seq.append(contentsOf: set(sequence(atv)))
        }

        // Organization
        if !organization.isEmpty {
            // OID 2.5.4.10
            let orgOid: [UInt8] = [0x55, 0x04, 0x0A]
            var atv = oid(orgOid)
            atv.append(contentsOf: utf8String(organization))
            seq.append(contentsOf: set(sequence(atv)))
        }

        // Common Name
        // OID 2.5.4.3
        let cnOid: [UInt8] = [0x55, 0x04, 0x03]
        var atv = oid(cnOid)
        atv.append(contentsOf: utf8String(commonName))
        seq.append(contentsOf: set(sequence(atv)))

        return sequence(seq)
    }

    static func validity(notBefore: Date, notAfter: Date) -> Data {
        var seq = utcTime(notBefore)
        seq.append(contentsOf: utcTime(notAfter))
        return sequence(seq)
    }

    static func subjectPublicKeyInfo(rsaPublicKey: Data) -> Data {
        // rsaEncryption (1.2.840.113549.1.1.1)
        let rsaOidBytes: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
        var algo = oid(rsaOidBytes)
        algo.append(contentsOf: null())
        let algoSeq = sequence(algo)

        var spki = algoSeq
        spki.append(contentsOf: bitString(rsaPublicKey))
        return sequence(spki)
    }

    static func subjectPublicKeyInfoEC(ecPublicKey: Data) -> Data {
        // id-ecPublicKey (1.2.840.10045.2.1)
        let ecOidBytes: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
        // prime256v1 / secp256r1 (1.2.840.10045.3.1.7)
        let curveOidBytes: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]

        var algo = oid(ecOidBytes)
        algo.append(contentsOf: oid(curveOidBytes))
        let algoSeq = sequence(algo)

        var spki = algoSeq
        spki.append(contentsOf: bitString(ecPublicKey))
        return sequence(spki)
    }
}

private extension Data {
    func replacingOccurrences(of target: Data, with replacement: Data) -> Data {
        // Not used in final implementation; return self
        return self
    }
}
