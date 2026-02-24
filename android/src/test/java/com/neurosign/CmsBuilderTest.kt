package com.neurosign

import org.bouncycastle.cms.CMSSignedData
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.junit.Assert.*
import org.junit.BeforeClass
import org.junit.Test
import java.security.MessageDigest
import java.security.Security

class CmsBuilderTest {

    companion object {
        @BeforeClass
        @JvmStatic
        fun setup() {
            if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) == null) {
                Security.addProvider(BouncyCastleProvider())
            }
        }
    }

    @Test
    fun buildCMSContainer_rsa_returnsDER() {
        val identity = TestSigningHelper.generateRSAIdentity()
        val hash = MessageDigest.getInstance("SHA-256").digest("test data".toByteArray())

        val cms = CmsBuilder.buildCMSContainer(hash, identity)

        assertTrue(cms.isNotEmpty())
        // DER SEQUENCE tag
        assertEquals(0x30.toByte(), cms[0])
    }

    @Test
    fun buildCMSContainer_ec_returnsDER() {
        val identity = TestSigningHelper.generateECIdentity()
        val hash = MessageDigest.getInstance("SHA-256").digest("test data".toByteArray())

        val cms = CmsBuilder.buildCMSContainer(hash, identity)

        assertTrue(cms.isNotEmpty())
        assertEquals(0x30.toByte(), cms[0])
    }

    @Test
    fun buildCMSContainer_rsa_parseable() {
        val identity = TestSigningHelper.generateRSAIdentity()
        val hash = MessageDigest.getInstance("SHA-256").digest("test".toByteArray())

        val cms = CmsBuilder.buildCMSContainer(hash, identity)

        // Should be parseable by BouncyCastle
        val signedData = CMSSignedData(cms)
        assertEquals(1, signedData.signerInfos.size())
        assertTrue(signedData.certificates.getMatches(null).count() > 0)
    }

    @Test
    fun buildCMSContainer_containsSigningCertV2() {
        val identity = TestSigningHelper.generateRSAIdentity()
        val hash = MessageDigest.getInstance("SHA-256").digest("test".toByteArray())

        val cms = CmsBuilder.buildCMSContainer(hash, identity)
        val signedData = CMSSignedData(cms)

        val signerInfo = signedData.signerInfos.signers.first()
        // OID 1.2.840.113549.1.9.16.2.47 = id-aa-signingCertificateV2
        val sigCertV2 = signerInfo.signedAttributes
            .get(org.bouncycastle.asn1.ASN1ObjectIdentifier("1.2.840.113549.1.9.16.2.47"))
        assertNotNull("CMS should contain signing-certificate-v2 attribute", sigCertV2)
    }
}
