import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

/**
 * Error codes thrown by Neurosign methods.
 */
export type NeurosignErrorCode =
  | 'PDF_GENERATION_FAILED'
  | 'SIGNATURE_FAILED'
  | 'CERTIFICATE_ERROR'
  | 'VERIFICATION_FAILED'
  | 'INVALID_INPUT'
  | 'CLEANUP_FAILED'
  | 'EXTERNAL_SIGNING_FAILED';

/**
 * Typed error thrown by Neurosign methods.
 */
export interface NeurosignError extends Error {
  code: NeurosignErrorCode;
}

/**
 * Type guard to check if an unknown error is a NeurosignError.
 */
export function isNeurosignError(error: unknown): error is NeurosignError {
  return (
    error instanceof Error &&
    'code' in error &&
    typeof (error as NeurosignError).code === 'string'
  );
}

export interface Spec extends TurboModule {
  /**
   * Generate a PDF document from a list of image file URLs.
   * Each image becomes a separate page in the PDF.
   *
   * iOS: UIGraphicsPDFRenderer
   * Android: android.graphics.pdf.PdfDocument
   */
  generatePdf(options: {
    imageUrls: string[];
    fileName?: string;
    pageSize?: string;
    pageMargin?: number;
    quality?: number;
  }): Promise<{
    pdfUrl: string;
    pageCount: number;
  }>;

  /**
   * Overlay a signature image onto one or more pages of a PDF document.
   * Returns a new file URL for the modified PDF.
   *
   * Coordinates are normalized (0-1 range relative to page dimensions).
   *
   * When `placements` array is provided, signatures are added to all
   * specified pages. Otherwise falls back to single page via
   * pageIndex/x/y/width/height fields.
   */
  addSignatureImage(options: {
    pdfUrl: string;
    signatureImageUrl: string;
    pageIndex: number;
    x: number;
    y: number;
    width: number;
    height: number;
    placements?: Array<{
      pageIndex: number;
      x: number;
      y: number;
      width: number;
      height: number;
    }>;
  }): Promise<{
    pdfUrl: string;
  }>;

  /**
   * Apply a PAdES-B-B digital signature to a PDF document.
   * Embeds a CMS/PKCS#7 signature container into the PDF.
   *
   * iOS: Security.framework + OpenSSL for CMS
   * Android: java.security + BouncyCastle for CMS
   */
  signPdf(options: {
    pdfUrl: string;
    certificateType: string;
    certificatePath?: string;
    certificatePassword?: string;
    keychainAlias?: string;
    reason?: string;
    location?: string;
    contactInfo?: string;
    signatureImageUrl?: string;
    pageIndex?: number;
    signatureX?: number;
    signatureY?: number;
    signatureWidth?: number;
    signatureHeight?: number;
  }): Promise<{
    pdfUrl: string;
    signatureValid: boolean;
    signerName: string;
    signedAt: string;
  }>;

  /**
   * Render a single PDF page to a PNG image file.
   * Used for previewing PDF pages in the signature placement UI.
   *
   * iOS: CGPDFDocument + UIGraphicsImageRenderer
   * Android: PdfRenderer + Bitmap
   */
  renderPdfPage(options: {
    pdfUrl: string;
    pageIndex: number;
    width: number;
    height: number;
  }): Promise<{
    imageUrl: string;
    pageWidth: number;
    pageHeight: number;
    pageCount: number;
  }>;

  /**
   * Verify all digital signatures in a PDF document.
   */
  verifySignature(pdfUrl: string): Promise<{
    signed: boolean;
    signatures: Array<{
      signerName: string;
      signedAt: string;
      valid: boolean;
      trusted: boolean;
      reason: string;
    }>;
  }>;

  /**
   * Import a PKCS#12 (.p12/.pfx) certificate into the device keychain/keystore.
   */
  importCertificate(options: {
    certificatePath: string;
    password: string;
    alias: string;
  }): Promise<{
    alias: string;
    subject: string;
    issuer: string;
    validFrom: string;
    validTo: string;
    serialNumber: string;
  }>;

  /**
   * Generate a self-signed X.509 certificate for testing purposes.
   */
  generateSelfSignedCertificate(options: {
    commonName: string;
    organization?: string;
    country?: string;
    validityDays?: number;
    alias: string;
    keyAlgorithm?: string; // "RSA" (default) or "EC"/"ECDSA"
  }): Promise<{
    alias: string;
    subject: string;
    issuer: string;
    validFrom: string;
    validTo: string;
    serialNumber: string;
  }>;

  /**
   * List all certificates stored in the device keychain/keystore.
   */
  listCertificates(): Promise<
    Array<{
      alias: string;
      subject: string;
      issuer: string;
      validFrom: string;
      validTo: string;
      serialNumber: string;
    }>
  >;

  /**
   * Delete a certificate from the device keychain/keystore.
   */
  deleteCertificate(alias: string): Promise<boolean>;

  /**
   * Prepare a PDF for external signing.
   * Builds the incremental update with signature placeholder, computes
   * ByteRange, and returns the SHA-256 hash of the byte ranges.
   *
   * The returned hash must be signed by an external provider, which returns
   * a CMS/PKCS#7 SignedData container. Pass that to completeExternalSigning().
   */
  prepareForExternalSigning(options: {
    pdfUrl: string;
    reason?: string;
    location?: string;
    contactInfo?: string;
  }): Promise<{
    preparedPdfUrl: string;
    hash: string;
    hashAlgorithm: string;
  }>;

  /**
   * Complete external signing by embedding a CMS/PKCS#7 signature
   * into the prepared PDF's /Contents placeholder.
   *
   * @param signature - base64-encoded DER CMS/PKCS#7 SignedData container
   */
  completeExternalSigning(options: {
    preparedPdfUrl: string;
    signature: string;
  }): Promise<{
    pdfUrl: string;
  }>;

  /**
   * Export a signature drawing from the native SignaturePad view to an image file.
   */
  exportSignature(
    viewTag: number,
    format: string,
    quality: number
  ): Promise<{
    imageUrl: string;
  }>;

  /**
   * Cleanup temporary files created by Neurosign.
   */
  cleanupTempFiles(): Promise<boolean>;
}

export default TurboModuleRegistry.getEnforcing<Spec>('Neurosign');
