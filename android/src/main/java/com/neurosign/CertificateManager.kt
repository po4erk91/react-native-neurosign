package com.neurosign

import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.asn1.x509.BasicConstraints
import org.bouncycastle.asn1.x509.Extension
import org.bouncycastle.asn1.x509.SubjectPublicKeyInfo
import org.bouncycastle.cert.X509v3CertificateBuilder
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.io.File
import java.io.FileInputStream
import java.math.BigInteger
import java.security.*
import java.security.cert.X509Certificate
import java.text.SimpleDateFormat
import java.util.*

/**
 * Manages X.509 certificates for PAdES signing.
 * Supports: .p12 import, Android KeyStore, self-signed generation via BouncyCastle.
 */
object CertificateManager {

    private const val KEYSTORE_TYPE = "AndroidKeyStore"
    private const val NEUROSIGN_PREFIX = "neurosign_"

    data class CertificateInfo(
        val alias: String,
        val subject: String,
        val issuer: String,
        val validFrom: String,
        val validTo: String,
        val serialNumber: String
    ) {
        fun toMap(): Map<String, String> = mapOf(
            "alias" to alias,
            "subject" to subject,
            "issuer" to issuer,
            "validFrom" to validFrom,
            "validTo" to validTo,
            "serialNumber" to serialNumber
        )
    }

    data class SigningIdentity(
        val privateKey: PrivateKey,
        val certificate: X509Certificate,
        val certificateChain: Array<X509Certificate>
    )

    // MARK: - Import PKCS#12

    fun importP12(filePath: String, password: String, alias: String): CertificateInfo {
        val path = filePath.removePrefix("file://")
        val file = File(path)
        require(file.exists()) { "Cannot read .p12 file at: $filePath" }

        val p12KeyStore = KeyStore.getInstance("PKCS12")
        FileInputStream(file).use { fis ->
            p12KeyStore.load(fis, password.toCharArray())
        }

        // Get the first alias from the P12
        val p12Alias = p12KeyStore.aliases().toList().firstOrNull()
            ?: throw IllegalStateException("No entries found in .p12 file")

        val privateKey = p12KeyStore.getKey(p12Alias, password.toCharArray()) as? PrivateKey
            ?: throw IllegalStateException("No private key found in .p12 file")

        val chain = p12KeyStore.getCertificateChain(p12Alias)
            ?.map { it as X509Certificate }
            ?: throw IllegalStateException("No certificate chain found in .p12 file")

        val cert = chain.first()

        // Store in Android KeyStore
        val androidKeyStore = KeyStore.getInstance(KEYSTORE_TYPE)
        androidKeyStore.load(null)

        val fullAlias = "$NEUROSIGN_PREFIX$alias"
        androidKeyStore.setKeyEntry(
            fullAlias,
            privateKey,
            null, // Android KeyStore doesn't use password
            chain.toTypedArray()
        )

        return extractCertInfo(cert, alias)
    }

    // MARK: - Generate Self-Signed Certificate

    fun generateSelfSigned(
        commonName: String,
        organization: String,
        country: String,
        validityDays: Int,
        alias: String,
        keyAlgorithm: String = "RSA"
    ): CertificateInfo {
        val isEC = keyAlgorithm.uppercase() == "EC" || keyAlgorithm.uppercase() == "ECDSA"

        val keyPair = if (isEC) {
            val gen = KeyPairGenerator.getInstance("EC")
            gen.initialize(java.security.spec.ECGenParameterSpec("secp256r1"), SecureRandom())
            gen.generateKeyPair()
        } else {
            val gen = KeyPairGenerator.getInstance("RSA")
            gen.initialize(2048, SecureRandom())
            gen.generateKeyPair()
        }

        val sigAlgorithm = if (isEC) "SHA256withECDSA" else "SHA256withRSA"

        val now = Date()
        val calendar = Calendar.getInstance()
        calendar.time = now
        calendar.add(Calendar.DAY_OF_YEAR, validityDays)
        val expiry = calendar.time

        // Build X.500 name
        val subjectParts = mutableListOf<String>()
        subjectParts.add("CN=$commonName")
        if (organization.isNotEmpty()) subjectParts.add("O=$organization")
        if (country.isNotEmpty()) subjectParts.add("C=$country")
        val x500Name = X500Name(subjectParts.joinToString(","))

        // Build certificate
        val serial = BigInteger(128, SecureRandom())
        val pubKeyInfo = SubjectPublicKeyInfo.getInstance(keyPair.public.encoded)

        val certBuilder = X509v3CertificateBuilder(
            x500Name,      // issuer (self-signed = subject)
            serial,
            now,
            expiry,
            x500Name,      // subject
            pubKeyInfo
        )

        // Add basic constraints (CA: false)
        certBuilder.addExtension(
            Extension.basicConstraints,
            true,
            BasicConstraints(false)
        )

        // Sign the certificate
        val contentSigner = JcaContentSignerBuilder(sigAlgorithm)
            .build(keyPair.private)

        val certHolder = certBuilder.build(contentSigner)
        val certificate = JcaX509CertificateConverter()
            .getCertificate(certHolder)

        // Store in Android KeyStore
        val androidKeyStore = KeyStore.getInstance(KEYSTORE_TYPE)
        androidKeyStore.load(null)

        val fullAlias = "$NEUROSIGN_PREFIX$alias"
        androidKeyStore.setKeyEntry(
            fullAlias,
            keyPair.private,
            null,
            arrayOf(certificate)
        )

        return extractCertInfo(certificate, alias)
    }

    // MARK: - List Certificates

    fun listCertificates(): List<CertificateInfo> {
        val keyStore = KeyStore.getInstance(KEYSTORE_TYPE)
        keyStore.load(null)

        return keyStore.aliases().toList()
            .filter { it.startsWith(NEUROSIGN_PREFIX) }
            .mapNotNull { fullAlias ->
                try {
                    val cert = keyStore.getCertificate(fullAlias) as? X509Certificate
                        ?: return@mapNotNull null
                    val alias = fullAlias.removePrefix(NEUROSIGN_PREFIX)
                    extractCertInfo(cert, alias)
                } catch (_: Exception) {
                    null
                }
            }
    }

    // MARK: - Delete Certificate

    fun deleteCertificate(alias: String): Boolean {
        val keyStore = KeyStore.getInstance(KEYSTORE_TYPE)
        keyStore.load(null)

        val fullAlias = "$NEUROSIGN_PREFIX$alias"
        return if (keyStore.containsAlias(fullAlias)) {
            keyStore.deleteEntry(fullAlias)
            true
        } else {
            false
        }
    }

    // MARK: - Get Signing Identity

    fun getSigningIdentity(alias: String): SigningIdentity {
        val keyStore = KeyStore.getInstance(KEYSTORE_TYPE)
        keyStore.load(null)

        val fullAlias = "$NEUROSIGN_PREFIX$alias"

        val privateKey = keyStore.getKey(fullAlias, null) as? PrivateKey
            ?: throw IllegalStateException("Private key not found for alias: $alias")

        val chain = keyStore.getCertificateChain(fullAlias)
            ?.map { it as X509Certificate }
            ?: throw IllegalStateException("Certificate chain not found for alias: $alias")

        return SigningIdentity(
            privateKey = privateKey,
            certificate = chain.first(),
            certificateChain = chain.toTypedArray()
        )
    }

    fun getSigningIdentityFromP12(filePath: String, password: String): SigningIdentity {
        val path = filePath.removePrefix("file://")
        val file = File(path)

        val p12KeyStore = KeyStore.getInstance("PKCS12")
        FileInputStream(file).use { fis ->
            p12KeyStore.load(fis, password.toCharArray())
        }

        val p12Alias = p12KeyStore.aliases().toList().firstOrNull()
            ?: throw IllegalStateException("No entries in .p12 file")

        val privateKey = p12KeyStore.getKey(p12Alias, password.toCharArray()) as PrivateKey
        val chain = p12KeyStore.getCertificateChain(p12Alias)
            .map { it as X509Certificate }

        return SigningIdentity(
            privateKey = privateKey,
            certificate = chain.first(),
            certificateChain = chain.toTypedArray()
        )
    }

    // MARK: - Private

    private fun extractCertInfo(cert: X509Certificate, alias: String): CertificateInfo {
        val dateFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
        dateFormat.timeZone = TimeZone.getTimeZone("UTC")

        return CertificateInfo(
            alias = alias,
            subject = cert.subjectX500Principal.name,
            issuer = cert.issuerX500Principal.name,
            validFrom = dateFormat.format(cert.notBefore),
            validTo = dateFormat.format(cert.notAfter),
            serialNumber = cert.serialNumber.toString(16).uppercase()
        )
    }
}
