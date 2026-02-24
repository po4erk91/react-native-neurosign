package com.neurosign

import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.asn1.x509.BasicConstraints
import org.bouncycastle.asn1.x509.Extension
import org.bouncycastle.asn1.x509.SubjectPublicKeyInfo
import org.bouncycastle.cert.X509v3CertificateBuilder
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.security.Security
import java.security.spec.ECGenParameterSpec
import java.util.Calendar
import java.util.Date

/**
 * Helper to create SigningIdentity instances for JVM unit tests
 * without requiring Android KeyStore.
 */
object TestSigningHelper {

    init {
        if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) == null) {
            Security.addProvider(BouncyCastleProvider())
        }
    }

    fun generateRSAIdentity(): CertificateManager.SigningIdentity {
        val keyPair = KeyPairGenerator.getInstance("RSA").apply {
            initialize(2048, SecureRandom())
        }.generateKeyPair()

        val certificate = buildSelfSignedCert(keyPair, "SHA256withRSA", "CN=Test RSA")

        return CertificateManager.SigningIdentity(
            privateKey = keyPair.private,
            certificate = certificate,
            certificateChain = listOf(certificate)
        )
    }

    fun generateECIdentity(): CertificateManager.SigningIdentity {
        val keyPair = KeyPairGenerator.getInstance("EC").apply {
            initialize(ECGenParameterSpec("secp256r1"), SecureRandom())
        }.generateKeyPair()

        val certificate = buildSelfSignedCert(keyPair, "SHA256withECDSA", "CN=Test EC")

        return CertificateManager.SigningIdentity(
            privateKey = keyPair.private,
            certificate = certificate,
            certificateChain = listOf(certificate)
        )
    }

    private fun buildSelfSignedCert(
        keyPair: java.security.KeyPair,
        sigAlgorithm: String,
        subjectDN: String
    ): java.security.cert.X509Certificate {
        val now = Date()
        val calendar = Calendar.getInstance()
        calendar.time = now
        calendar.add(Calendar.DAY_OF_YEAR, 365)
        val expiry = calendar.time

        val x500Name = X500Name(subjectDN)
        val serial = BigInteger(128, SecureRandom())
        val pubKeyInfo = SubjectPublicKeyInfo.getInstance(keyPair.public.encoded)

        val certBuilder = X509v3CertificateBuilder(
            x500Name, serial, now, expiry, x500Name, pubKeyInfo
        )
        certBuilder.addExtension(Extension.basicConstraints, true, BasicConstraints(false))

        val contentSigner = JcaContentSignerBuilder(sigAlgorithm).build(keyPair.private)
        val certHolder = certBuilder.build(contentSigner)

        return JcaX509CertificateConverter()
            .setProvider(BouncyCastleProvider.PROVIDER_NAME)
            .getCertificate(certHolder)
    }
}
