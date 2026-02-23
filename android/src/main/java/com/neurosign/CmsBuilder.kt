package com.neurosign

import org.bouncycastle.asn1.ASN1EncodableVector
import org.bouncycastle.asn1.ASN1Integer
import org.bouncycastle.asn1.ASN1ObjectIdentifier
import org.bouncycastle.asn1.DERNull
import org.bouncycastle.asn1.DEROctetString
import org.bouncycastle.asn1.DERSet
import org.bouncycastle.asn1.cms.Attribute
import org.bouncycastle.asn1.cms.AttributeTable
import org.bouncycastle.asn1.cms.CMSAttributes
import org.bouncycastle.asn1.cms.ContentInfo
import org.bouncycastle.asn1.cms.SignedData
import org.bouncycastle.asn1.cms.SignerInfo
import org.bouncycastle.asn1.ess.ESSCertIDv2
import org.bouncycastle.asn1.ess.SigningCertificateV2
import org.bouncycastle.asn1.nist.NISTObjectIdentifiers
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.asn1.x509.AlgorithmIdentifier
import org.bouncycastle.asn1.x509.GeneralName
import org.bouncycastle.asn1.x509.GeneralNames
import org.bouncycastle.asn1.x509.IssuerSerial
import org.bouncycastle.cert.jcajce.JcaCertStore
import org.bouncycastle.cms.CMSAbsentContent
import org.bouncycastle.cms.CMSAttributeTableGenerator
import org.bouncycastle.cms.CMSSignedData
import org.bouncycastle.cms.CMSSignedDataGenerator
import org.bouncycastle.cms.DefaultSignedAttributeTableGenerator
import org.bouncycastle.cms.jcajce.JcaSignerInfoGeneratorBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import org.bouncycastle.operator.jcajce.JcaDigestCalculatorProviderBuilder
import java.security.MessageDigest

/**
 * Builds CMS/PKCS#7 containers for PAdES-B-B digital signatures.
 *
 * Handles:
 * - Auto-detection of signature algorithm (RSA, EC/ECDSA)
 * - ESSCertIDv2 (signing-certificate-v2) attribute for PAdES B-B compliance
 * - SHA-256 AlgorithmIdentifier fix for Adobe Acrobat compatibility
 * - Stripping of CMSAlgorithmProtection and signingTime attributes
 */
internal object CmsBuilder {

    /**
     * Build a CMS/PKCS#7 detached signature container.
     *
     * @param hash     Pre-computed SHA-256 hash of the PDF byte ranges
     * @param identity Signing identity (private key + certificate chain)
     * @return DER-encoded CMS container bytes
     */
    fun buildCMSContainer(
        hash: ByteArray,
        identity: CertificateManager.SigningIdentity
    ): ByteArray {
        val certificate = identity.certificate
        val privateKey = identity.privateKey

        val generator = CMSSignedDataGenerator()

        // Auto-detect signature algorithm based on key type and size
        val signatureAlgorithm = when (privateKey.algorithm) {
            "EC", "ECDSA" -> {
                val keySize = try {
                    val ecKey = privateKey as java.security.interfaces.ECPrivateKey
                    ecKey.params.order.bitLength()
                } catch (_: Exception) { 256 }
                if (keySize > 384) "SHA512withECDSA" else "SHA256withECDSA"
            }
            "RSA" -> "SHA256withRSA"
            else -> throw IllegalArgumentException(
                "Unsupported key algorithm: ${privateKey.algorithm}. Only RSA and EC/ECDSA are supported."
            )
        }

        val contentSigner = JcaContentSignerBuilder(signatureAlgorithm)
            .build(privateKey)

        val digestCalculatorProvider = JcaDigestCalculatorProviderBuilder().build()

        // SHA-256 AlgorithmIdentifier with explicit NULL parameter.
        // Adobe Acrobat requires NULL in AlgorithmIdentifier for SHA-256.
        val sha256AlgId = AlgorithmIdentifier(NISTObjectIdentifiers.id_sha256, DERNull.INSTANCE)

        // Build ESSCertIDv2 for signing-certificate-v2 attribute (mandatory for PAdES B-B)
        val certHash = MessageDigest.getInstance("SHA-256").digest(certificate.encoded)
        val issuerName = GeneralName(X500Name.getInstance(certificate.issuerX500Principal.encoded))
        val issuerSerialObj = IssuerSerial(
            GeneralNames(issuerName),
            ASN1Integer(certificate.serialNumber)
        )

        val signingCertV2 = SigningCertificateV2(arrayOf(
            ESSCertIDv2(sha256AlgId, certHash, issuerSerialObj)
        ))
        val sigCertV2Oid = ASN1ObjectIdentifier("1.2.840.113549.1.9.16.2.47")

        // Build signed attributes table
        val attrsVector = ASN1EncodableVector()
        attrsVector.add(Attribute(CMSAttributes.messageDigest, DERSet(DEROctetString(hash))))
        attrsVector.add(Attribute(sigCertV2Oid, DERSet(signingCertV2)))
        val signedAttrsTable = AttributeTable(attrsVector)
        val baseGen = DefaultSignedAttributeTableGenerator(signedAttrsTable)

        // Strip CMSAlgorithmProtection and signingTime (not part of PAdES B-B profile)
        val cmsAlgProtectOid = ASN1ObjectIdentifier("1.2.840.113549.1.9.52")
        val signingTimeOid = ASN1ObjectIdentifier("1.2.840.113549.1.9.5")
        val signedAttrsGen = CMSAttributeTableGenerator { params ->
            var table = baseGen.getAttributes(params)
            table = table.remove(cmsAlgProtectOid)
            table = table.remove(signingTimeOid)
            table
        }

        val signerInfoGenerator = JcaSignerInfoGeneratorBuilder(digestCalculatorProvider)
            .setSignedAttributeGenerator(signedAttrsGen)
            .build(contentSigner, certificate)

        generator.addSignerInfoGenerator(signerInfoGenerator)

        val certStore = JcaCertStore(identity.certificateChain)
        generator.addCertificates(certStore)

        // Use CMSAbsentContent for detached signature
        val signedData = generator.generate(CMSAbsentContent(), false)

        // Post-process: ensure SHA-256 AlgorithmIdentifier includes NULL parameter
        return fixSha256AlgorithmIdentifier(signedData)
    }

    /**
     * Fix SHA-256 AlgorithmIdentifier in CMS SignedData to include explicit NULL parameter.
     *
     * BouncyCastle encodes SHA-256 as: SEQUENCE { OID sha256 } (no NULL)
     * Adobe Acrobat requires:          SEQUENCE { OID sha256, NULL }
     */
    private fun fixSha256AlgorithmIdentifier(signedData: CMSSignedData): ByteArray {
        val contentInfo = signedData.toASN1Structure()
        val sd = SignedData.getInstance(contentInfo.content)

        val sha256WithNull = AlgorithmIdentifier(NISTObjectIdentifiers.id_sha256, DERNull.INSTANCE)

        // Fix digestAlgorithms SET
        val fixedDigestAlgs = ASN1EncodableVector()
        for (alg in sd.digestAlgorithms) {
            val algId = AlgorithmIdentifier.getInstance(alg)
            if (algId.algorithm == NISTObjectIdentifiers.id_sha256) {
                fixedDigestAlgs.add(sha256WithNull)
            } else {
                fixedDigestAlgs.add(algId)
            }
        }

        // Fix signerInfos
        val fixedSignerInfos = ASN1EncodableVector()
        for (si in sd.signerInfos) {
            val signerInfo = SignerInfo.getInstance(si)
            val fixedDigestAlg = if (signerInfo.digestAlgorithm.algorithm == NISTObjectIdentifiers.id_sha256) {
                sha256WithNull
            } else {
                signerInfo.digestAlgorithm
            }
            val fixedSignerInfo = SignerInfo(
                signerInfo.sid,
                fixedDigestAlg,
                signerInfo.authenticatedAttributes,
                signerInfo.digestEncryptionAlgorithm,
                signerInfo.encryptedDigest,
                signerInfo.unauthenticatedAttributes
            )
            fixedSignerInfos.add(fixedSignerInfo)
        }

        // Rebuild SignedData with fixed algorithms
        val fixedSD = SignedData(
            DERSet(fixedDigestAlgs),
            sd.encapContentInfo,
            sd.certificates,
            sd.getCRLs(),
            DERSet(fixedSignerInfos)
        )

        val fixedContentInfo = ContentInfo(contentInfo.contentType, fixedSD)
        return fixedContentInfo.getEncoded("DER")
    }
}
