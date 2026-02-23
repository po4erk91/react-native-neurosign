import Foundation
import Security

/// Manages X.509 certificates for PAdES signing.
/// Supports: .p12 import, iOS Keychain storage, self-signed generation via Security.framework.
@objcMembers
public class CertificateManager: NSObject {

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

    // MARK: - Shared URL Parser

    private static func resolveFileUrl(_ fileUrl: String) -> URL? {
        if let url = URL(string: fileUrl), url.isFileURL {
            return url
        }
        if fileUrl.hasPrefix("/") {
            return URL(fileURLWithPath: fileUrl)
        }
        if fileUrl.hasPrefix("file://") {
            let path = String(fileUrl.dropFirst("file://".count))
            return URL(fileURLWithPath: path)
        }
        return URL(string: fileUrl)
    }

    // MARK: - Import PKCS#12

    public static func importP12(
        fileUrl: String,
        password: String,
        alias: String
    ) throws -> CertificateInfo {
        guard let url = resolveFileUrl(fileUrl) else {
            throw NSError(domain: "Neurosign", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid file URL: \(fileUrl)"
            ])
        }

        let p12Data: Data
        do {
            p12Data = try Data(contentsOf: url)
        } catch {
            throw NSError(domain: "Neurosign", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Cannot read .p12 file at: \(fileUrl) — \(error.localizedDescription)"
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

        guard let identityRef = firstItem[kSecImportItemIdentity as String] else {
            throw NSError(domain: "Neurosign", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "No identity found in .p12 file"
            ])
        }
        // swiftlint:disable:next force_cast
        let identity = identityRef as! SecIdentity

        // Extract certificate from identity
        var certificate: SecCertificate?
        let certStatus = SecIdentityCopyCertificate(identity, &certificate)

        guard certStatus == errSecSuccess, let cert = certificate else {
            throw NSError(domain: "Neurosign", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Cannot extract certificate from identity (OSStatus \(certStatus))"
            ])
        }

        // Extract private key
        var privateKey: SecKey?
        let keyStatus = SecIdentityCopyPrivateKey(identity, &privateKey)

        guard keyStatus == errSecSuccess, privateKey != nil else {
            throw NSError(domain: "Neurosign", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Cannot extract private key from identity (OSStatus \(keyStatus))"
            ])
        }

        // Store in Keychain with alias as label
        try storeIdentityInKeychain(identity: identity, certificate: cert, alias: alias)

        // Extract certificate chain
        let chain = (firstItem[kSecImportItemCertChain as String] as? [SecCertificate]) ?? [cert]

        return try extractCertificateInfo(from: cert, alias: alias, chain: chain)
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
        guard let expiry = Calendar.current.date(byAdding: .day, value: validityDays, to: now) else {
            throw NSError(domain: "Neurosign", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "Invalid validity period: \(validityDays) days"
            ])
        }

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

        return try extractCertificateInfo(from: certificate, alias: alias, chain: nil)
    }

    // MARK: - List Certificates

    public static func listCertificates() -> [CertificateInfo] {
        // Use label-prefix filtered query
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
            kSecReturnAttributes as String: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item -> CertificateInfo? in
            guard let label = item[kSecAttrLabel as String] as? String,
                  label.hasPrefix("com.neurosign."),
                  let certValue = item[kSecValueRef as String] else {
                return nil
            }
            // swiftlint:disable:next force_cast
            let certRef = certValue as! SecCertificate
            let alias = String(label.dropFirst("com.neurosign.".count))
            return try? extractCertificateInfo(from: certRef, alias: alias, chain: nil)
        }
    }

    // MARK: - Delete Certificate

    public static func deleteCertificate(alias: String) throws -> Bool {
        // Delete certificate
        let certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: "com.neurosign.\(alias)",
        ]
        let certStatus = SecItemDelete(certQuery as CFDictionary)

        // Delete private key
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: "com.neurosign.\(alias).key",
        ]
        let keyStatus = SecItemDelete(keyQuery as CFDictionary)

        // Return true only if at least one item was actually deleted
        let certDeleted = certStatus == errSecSuccess
        let keyDeleted = keyStatus == errSecSuccess

        if !certDeleted && certStatus != errSecItemNotFound {
            throw NSError(domain: "Neurosign", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Failed to delete certificate: OSStatus \(certStatus)"
            ])
        }
        if !keyDeleted && keyStatus != errSecItemNotFound {
            throw NSError(domain: "Neurosign", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Failed to delete private key: OSStatus \(keyStatus)"
            ])
        }

        return certDeleted || keyDeleted
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

        guard certStatus == errSecSuccess, let certRef = certResult else {
            throw NSError(domain: "Neurosign", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "Certificate not found for alias: \(alias)"
            ])
        }
        // swiftlint:disable:next force_cast
        let certificate = certRef as! SecCertificate

        // Find private key
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: "com.neurosign.\(alias).key",
            kSecReturnRef as String: true,
        ]

        var keyResult: CFTypeRef?
        let keyStatus = SecItemCopyMatching(keyQuery as CFDictionary, &keyResult)

        guard keyStatus == errSecSuccess, let keyRef = keyResult else {
            throw NSError(domain: "Neurosign", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "Private key not found for alias: \(alias)"
            ])
        }
        // swiftlint:disable:next force_cast
        let privateKey = keyRef as! SecKey

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
        guard let url = resolveFileUrl(filePath) else {
            throw NSError(domain: "Neurosign", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "Invalid file path: \(filePath)"
            ])
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

        guard let identityRef = firstItem[kSecImportItemIdentity as String] else {
            throw NSError(domain: "Neurosign", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "No identity in .p12 file"
            ])
        }
        // swiftlint:disable:next force_cast
        let identity = identityRef as! SecIdentity

        var certificate: SecCertificate?
        let certOsStatus = SecIdentityCopyCertificate(identity, &certificate)
        guard certOsStatus == errSecSuccess, let cert = certificate else {
            throw NSError(domain: "Neurosign", code: 32, userInfo: [
                NSLocalizedDescriptionKey: "Cannot extract certificate (OSStatus \(certOsStatus))"
            ])
        }

        var privateKey: SecKey?
        let keyOsStatus = SecIdentityCopyPrivateKey(identity, &privateKey)
        guard keyOsStatus == errSecSuccess, let key = privateKey else {
            throw NSError(domain: "Neurosign", code: 33, userInfo: [
                NSLocalizedDescriptionKey: "Cannot extract private key (OSStatus \(keyOsStatus))"
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
        let keyOsStatus = SecIdentityCopyPrivateKey(identity, &privateKey)
        guard keyOsStatus == errSecSuccess, let key = privateKey else {
            throw NSError(domain: "Neurosign", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Failed to extract private key for storage (OSStatus \(keyOsStatus))"
            ])
        }

        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrLabel as String: "com.neurosign.\(alias).key",
            kSecValueRef as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(keyQuery as CFDictionary)
        let keyStatus = SecItemAdd(keyQuery as CFDictionary, nil)
        if keyStatus != errSecSuccess && keyStatus != errSecDuplicateItem {
            throw NSError(domain: "Neurosign", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Failed to store private key: \(keyStatus)"
            ])
        }
    }

    // MARK: - Private: Extract Certificate Info

    private static func extractCertificateInfo(from certificate: SecCertificate, alias: String, chain: [SecCertificate]?) throws -> CertificateInfo {
        let subject = SecCertificateCopySubjectSummary(certificate) as? String ?? "Unknown"
        let certData = SecCertificateCopyData(certificate) as Data

        // Parse real DER info
        let serialNumber = extractSerialNumber(from: certData)
        let dates = extractValidityDates(from: certData)

        // For issuer: try to get from chain or parse DER
        let issuer: String
        if let chain = chain, chain.count > 1 {
            // The last cert in the chain is typically the issuer/CA
            issuer = SecCertificateCopySubjectSummary(chain.last!) as? String ?? subject
        } else {
            // Self-signed or no chain: extract issuer from DER
            issuer = extractIssuerName(from: certData) ?? subject
        }

        return CertificateInfo(
            alias: alias,
            subject: subject,
            issuer: issuer,
            validFrom: dates.notBefore,
            validTo: dates.notAfter,
            serialNumber: serialNumber
        )
    }

    // MARK: - Private: DER Parsing Helpers

    /// Extract the actual serial number from the certificate DER.
    private static func extractSerialNumber(from certData: Data) -> String {
        let bytes = [UInt8](certData)
        guard bytes.count > 10 else { return "unknown" }

        var pos = skipTag(bytes: bytes, offset: 0) // outer SEQUENCE
        pos = skipTag(bytes: bytes, offset: pos)    // TBS SEQUENCE

        // Skip version [0] if present
        if pos < bytes.count && bytes[pos] == 0xA0 {
            pos = skipTLVFull(bytes: bytes, offset: pos)
        }

        // Read serial number INTEGER
        guard pos < bytes.count, bytes[pos] == 0x02 else { return "unknown" }
        pos += 1 // skip tag
        guard pos < bytes.count else { return "unknown" }

        let length: Int
        if bytes[pos] & 0x80 == 0 {
            length = Int(bytes[pos])
            pos += 1
        } else {
            let numLenBytes = Int(bytes[pos] & 0x7F)
            pos += 1
            var len = 0
            for i in 0..<numLenBytes {
                guard pos + i < bytes.count else { return "unknown" }
                len = (len << 8) | Int(bytes[pos + i])
            }
            pos += numLenBytes
            length = len
        }

        guard pos + length <= bytes.count else { return "unknown" }
        let serialBytes = bytes[pos..<(pos + length)]
        return serialBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Extract validity dates from the certificate DER structure.
    private static func extractValidityDates(from certData: Data) -> (notBefore: String, notAfter: String) {
        let bytes = [UInt8](certData)
        let formatter = ISO8601DateFormatter()

        guard bytes.count > 10 else {
            return fallbackDates(formatter: formatter)
        }

        var pos = skipTag(bytes: bytes, offset: 0) // outer SEQUENCE
        pos = skipTag(bytes: bytes, offset: pos)    // TBS SEQUENCE

        // Skip version [0] if present
        if pos < bytes.count && bytes[pos] == 0xA0 {
            pos = skipTLVFull(bytes: bytes, offset: pos)
        }

        // Skip serial number
        pos = skipTLVFull(bytes: bytes, offset: pos)

        // Skip signature algorithm
        pos = skipTLVFull(bytes: bytes, offset: pos)

        // Skip issuer
        pos = skipTLVFull(bytes: bytes, offset: pos)

        // Now at Validity SEQUENCE
        guard pos < bytes.count, bytes[pos] == 0x30 else {
            return fallbackDates(formatter: formatter)
        }

        let validityContentStart = skipTag(bytes: bytes, offset: pos)

        // Parse notBefore
        let notBefore = parseDERTime(bytes: bytes, offset: validityContentStart)
        let notBeforeEnd = skipTLVFull(bytes: bytes, offset: validityContentStart)

        // Parse notAfter
        let notAfter = parseDERTime(bytes: bytes, offset: notBeforeEnd)

        let notBeforeStr: String
        if let date = notBefore {
            notBeforeStr = formatter.string(from: date)
        } else {
            notBeforeStr = formatter.string(from: Date())
        }

        let notAfterStr: String
        if let date = notAfter {
            notAfterStr = formatter.string(from: date)
        } else {
            notAfterStr = formatter.string(from: Date().addingTimeInterval(365 * 24 * 60 * 60))
        }

        return (notBefore: notBeforeStr, notAfter: notAfterStr)
    }

    private static func fallbackDates(formatter: ISO8601DateFormatter) -> (notBefore: String, notAfter: String) {
        let now = Date()
        return (
            notBefore: formatter.string(from: now),
            notAfter: formatter.string(from: now.addingTimeInterval(365 * 24 * 60 * 60))
        )
    }

    /// Parse a UTCTime or GeneralizedTime from DER bytes.
    private static func parseDERTime(bytes: [UInt8], offset: Int) -> Date? {
        guard offset < bytes.count else { return nil }
        let tag = bytes[offset]
        var pos = offset + 1
        guard pos < bytes.count else { return nil }

        let length: Int
        if bytes[pos] & 0x80 == 0 {
            length = Int(bytes[pos])
            pos += 1
        } else {
            let numLenBytes = Int(bytes[pos] & 0x7F)
            pos += 1
            var len = 0
            for i in 0..<numLenBytes {
                guard pos + i < bytes.count else { return nil }
                len = (len << 8) | Int(bytes[pos + i])
            }
            pos += numLenBytes
            length = len
        }

        guard pos + length <= bytes.count else { return nil }
        let timeBytes = bytes[pos..<(pos + length)]
        guard let timeStr = String(bytes: timeBytes, encoding: .ascii) else { return nil }

        let df = DateFormatter()
        df.timeZone = TimeZone(identifier: "UTC")
        df.locale = Locale(identifier: "en_US_POSIX")

        if tag == 0x17 { // UTCTime
            df.dateFormat = "yyMMddHHmmss'Z'"
            return df.date(from: timeStr)
        } else if tag == 0x18 { // GeneralizedTime
            df.dateFormat = "yyyyMMddHHmmss'Z'"
            return df.date(from: timeStr)
        }
        return nil
    }

    /// Extract issuer common name from DER.
    private static func extractIssuerName(from certData: Data) -> String? {
        let bytes = [UInt8](certData)
        guard bytes.count > 10 else { return nil }

        var pos = skipTag(bytes: bytes, offset: 0) // outer SEQUENCE
        pos = skipTag(bytes: bytes, offset: pos)    // TBS SEQUENCE

        // Skip version [0] if present
        if pos < bytes.count && bytes[pos] == 0xA0 {
            pos = skipTLVFull(bytes: bytes, offset: pos)
        }

        // Skip serial number
        pos = skipTLVFull(bytes: bytes, offset: pos)

        // Skip signature algorithm
        pos = skipTLVFull(bytes: bytes, offset: pos)

        // Now at issuer Name (SEQUENCE of RDNs)
        guard pos < bytes.count else { return nil }
        let issuerStart = pos
        let issuerEnd = skipTLVFull(bytes: bytes, offset: pos)
        let issuerContentStart = skipTag(bytes: bytes, offset: issuerStart)

        // Look for CN OID (2.5.4.3) = 55 04 03
        let cnOid: [UInt8] = [0x55, 0x04, 0x03]
        var searchPos = issuerContentStart
        while searchPos < issuerEnd {
            // Each RDN is a SET
            guard searchPos < bytes.count, bytes[searchPos] == 0x31 else { break }
            let setContentStart = skipTag(bytes: bytes, offset: searchPos)
            let setEnd = skipTLVFull(bytes: bytes, offset: searchPos)

            // Inside SET: SEQUENCE { OID, value }
            let attrPos = setContentStart
            guard attrPos < bytes.count, bytes[attrPos] == 0x30 else {
                searchPos = setEnd
                continue
            }
            let seqContentStart = skipTag(bytes: bytes, offset: attrPos)

            // Read OID
            guard seqContentStart < bytes.count, bytes[seqContentStart] == 0x06 else {
                searchPos = setEnd
                continue
            }
            let oidLength = Int(bytes[seqContentStart + 1])
            let oidStart = seqContentStart + 2
            guard oidStart + oidLength <= bytes.count else {
                searchPos = setEnd
                continue
            }

            let oid = Array(bytes[oidStart..<(oidStart + oidLength)])
            if oid == cnOid {
                // Read the value (UTF8String, PrintableString, etc.)
                let valuePos = oidStart + oidLength
                guard valuePos < bytes.count else {
                    searchPos = setEnd
                    continue
                }
                let valueContentStart = skipTag(bytes: bytes, offset: valuePos)
                let valueEnd = skipTLVFull(bytes: bytes, offset: valuePos)
                guard valueContentStart < valueEnd, valueEnd <= bytes.count else {
                    searchPos = setEnd
                    continue
                }
                return String(bytes: bytes[valueContentStart..<valueEnd], encoding: .utf8)
            }

            searchPos = setEnd
        }

        return nil
    }

    // MARK: - DER Helpers

    private static func skipTag(bytes: [UInt8], offset: Int) -> Int {
        guard offset < bytes.count else { return offset }
        let pos = offset + 1
        guard pos < bytes.count else { return pos }
        if bytes[pos] & 0x80 == 0 {
            return pos + 1
        } else {
            let numLenBytes = Int(bytes[pos] & 0x7F)
            guard numLenBytes <= 4 else { return min(pos + 1, bytes.count) }
            return min(pos + 1 + numLenBytes, bytes.count)
        }
    }

    private static func skipTLVFull(bytes: [UInt8], offset: Int) -> Int {
        guard offset < bytes.count else { return offset }
        var pos = offset + 1
        guard pos < bytes.count else { return pos }

        var length = 0
        if bytes[pos] & 0x80 == 0 {
            length = Int(bytes[pos])
            pos += 1
        } else {
            let numLenBytes = Int(bytes[pos] & 0x7F)
            guard numLenBytes <= 4 else { return min(pos + 1, bytes.count) }
            pos += 1
            for i in 0..<numLenBytes {
                guard pos + i < bytes.count else { return bytes.count }
                length = (length << 8) | Int(bytes[pos + i])
            }
            pos += numLenBytes
        }

        return min(pos + length, bytes.count)
    }

    // MARK: - Private: Build Self-Signed Certificate DER

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

        var tbs = Data()

        // Version: v3 (2)
        tbs.append(contentsOf: DER.contextTag(0, value: DER.integer(Data([0x02]))))

        // Serial Number (use SecRandomCopyBytes for crypto-safe randomness)
        var serialBytes = [UInt8](repeating: 0, count: 8)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, serialBytes.count, &serialBytes)
        if randomStatus != errSecSuccess {
            // Fallback to SystemRandomNumberGenerator (still arc4random on Apple)
            serialBytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
        }
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

        // X.509 v3 Extensions
        var extensions = Data()

        // Basic Constraints: CA=FALSE
        let basicConstraintsOid: [UInt8] = [0x55, 0x1D, 0x13]
        let bcValue = DER.sequence(Data()) // empty sequence = CA:FALSE
        var bcAttr = DER.oid(basicConstraintsOid)
        bcAttr.append(contentsOf: DER.octetString(bcValue))
        extensions.append(contentsOf: DER.sequence(bcAttr))

        // Key Usage: digitalSignature, nonRepudiation
        let keyUsageOid: [UInt8] = [0x55, 0x1D, 0x0F]
        let keyUsageBits = Data([0x03, 0x02, 0x06, 0xC0]) // BIT STRING: digitalSignature + nonRepudiation
        var kuAttr = DER.oid(keyUsageOid)
        kuAttr.append(contentsOf: DER.tag(0x01, content: Data([0xFF]))) // critical = TRUE
        kuAttr.append(contentsOf: DER.octetString(keyUsageBits))
        extensions.append(contentsOf: DER.sequence(kuAttr))

        tbs.append(contentsOf: DER.contextTag(3, value: DER.sequence(extensions)))

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
        // Validate PrintableString character set
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 '()+,-./:=?")
        let filtered = string.unicodeScalars.filter { allowed.contains($0) }
        let sanitized = String(String.UnicodeScalarView(filtered))
        return tag(0x13, content: Data(sanitized.utf8))
    }

    /// Encode a date as UTCTime (< 2050) or GeneralizedTime (>= 2050).
    static func time(_ date: Date) -> Data {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: date)

        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")

        if year >= 2050 {
            // GeneralizedTime (tag 0x18)
            formatter.dateFormat = "yyyyMMddHHmmss'Z'"
            let str = formatter.string(from: date)
            return tag(0x18, content: Data(str.utf8))
        } else {
            // UTCTime (tag 0x17)
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            let str = formatter.string(from: date)
            return tag(0x17, content: Data(str.utf8))
        }
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
        } else if length < 16_777_216 {
            return [0x83, UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
        } else {
            return [0x84, UInt8(length >> 24), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
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
            let countryOid: [UInt8] = [0x55, 0x04, 0x06]
            var atv = oid(countryOid)
            atv.append(contentsOf: printableString(country))
            seq.append(contentsOf: set(sequence(atv)))
        }

        // Organization
        if !organization.isEmpty {
            let orgOid: [UInt8] = [0x55, 0x04, 0x0A]
            var atv = oid(orgOid)
            atv.append(contentsOf: utf8String(organization))
            seq.append(contentsOf: set(sequence(atv)))
        }

        // Common Name
        if !commonName.isEmpty {
            let cnOid: [UInt8] = [0x55, 0x04, 0x03]
            var atv = oid(cnOid)
            atv.append(contentsOf: utf8String(commonName))
            seq.append(contentsOf: set(sequence(atv)))
        }

        return sequence(seq)
    }

    static func validity(notBefore: Date, notAfter: Date) -> Data {
        var seq = time(notBefore)
        seq.append(contentsOf: time(notAfter))
        return sequence(seq)
    }

    static func subjectPublicKeyInfo(rsaPublicKey: Data) -> Data {
        let rsaOidBytes: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
        var algo = oid(rsaOidBytes)
        algo.append(contentsOf: null())
        let algoSeq = sequence(algo)

        var spki = algoSeq
        spki.append(contentsOf: bitString(rsaPublicKey))
        return sequence(spki)
    }

    static func subjectPublicKeyInfoEC(ecPublicKey: Data) -> Data {
        let ecOidBytes: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
        let curveOidBytes: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]

        var algo = oid(ecOidBytes)
        algo.append(contentsOf: oid(curveOidBytes))
        let algoSeq = sequence(algo)

        var spki = algoSeq
        spki.append(contentsOf: bitString(ecPublicKey))
        return sequence(spki)
    }
}
