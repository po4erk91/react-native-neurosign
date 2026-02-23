# react-native-neurosign

Native PDF generation from images with PAdES digital signatures and signature pad for React Native.

[![npm version](https://img.shields.io/npm/v/react-native-neurosign.svg)](https://www.npmjs.com/package/react-native-neurosign)
[![license](https://img.shields.io/npm/l/react-native-neurosign.svg)](https://github.com/po4erk91/react-native-neurosign/blob/main/LICENSE)
![iOS 16+](https://img.shields.io/badge/iOS-16%2B-blue)
![Android 7+](https://img.shields.io/badge/Android-7%2B-green)
![New Architecture](https://img.shields.io/badge/RN-New%20Architecture-purple)

## Features

- **PDF Generation** — create multi-page PDFs from images with configurable page size, margins, and quality
- **Signature Drawing** — native signature pad powered by PencilKit (iOS) with pressure sensitivity, undo/redo
- **Signature Placement** — interactive drag & pinch-to-resize overlay on PDF pages with multi-page support
- **PAdES-B-B Digital Signatures** — sign PDFs with CMS/PKCS#7 containers conforming to PAdES baseline
- **Certificate Management** — import `.p12`/`.pfx`, generate self-signed X.509 certificates, list & delete from keychain/keystore
- **Signature Verification** — verify all digital signatures in a PDF document
- **External Signing** — prepare hash for remote/server-side signing and embed the resulting CMS container
- **New Architecture** — built with TurboModules + Fabric (React Native 0.79+)

## Installation

```bash
npm install react-native-neurosign
# or
yarn add react-native-neurosign
```

### iOS

```bash
cd ios && pod install
```

### Android

No additional steps — auto-linked via React Native CLI.

> **Requirements:** React Native 0.79+ (New Architecture), iOS 16+, Android SDK 24+ (Android 7.0)

## Quick Start

```tsx
import Neurosign, { SignaturePad, SignaturePlacement } from 'react-native-neurosign';

// 1. Generate PDF from images
const pdf = await Neurosign.generatePdf({
  imageUrls: ['file:///path/to/photo1.jpg', 'file:///path/to/photo2.jpg'],
  fileName: 'document',
  pageSize: 'A4',
  pageMargin: 20,
  quality: 90,
});

// 2. Draw a signature (via SignaturePad ref)
signatureRef.current?.exportSignature('png', 90);

// 3. Place signature on PDF (via SignaturePlacement component)
// User drags and resizes → onPlacementConfirmed returns normalized coordinates

// 4. Apply visual signature overlay
const overlaid = await Neurosign.addSignatureImage({
  pdfUrl: pdf.pdfUrl,
  signatureImageUrl: 'file:///path/to/signature.png',
  pageIndex: 0,
  x: 0.6, y: 0.85, width: 0.3, height: 0.1,
});

// 5. Digitally sign with PAdES-B-B
const signed = await Neurosign.signPdf({
  pdfUrl: overlaid.pdfUrl,
  certificateType: 'selfSigned',
  reason: 'Document approval',
  location: 'Kyiv, Ukraine',
});
```

## API Reference

### `Neurosign` — Default Export

The main native module. All methods return Promises.

---

#### `generatePdf(options)`

Generate a PDF document from an array of images.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `imageUrls` | `string[]` | Yes | Array of image file URLs |
| `fileName` | `string` | No | Output file name (without extension) |
| `pageSize` | `string` | No | Page size, e.g. `"A4"` |
| `pageMargin` | `number` | No | Margin in points |
| `quality` | `number` | No | Image quality (0–100) |

**Returns:** `{ pdfUrl: string, pageCount: number }`

```ts
const result = await Neurosign.generatePdf({
  imageUrls: [photoUri],
  fileName: 'scan',
  pageSize: 'A4',
  quality: 85,
});
console.log(result.pdfUrl, result.pageCount);
```

---

#### `addSignatureImage(options)`

Overlay a signature image onto one or more PDF pages.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `pdfUrl` | `string` | Yes | Source PDF file URL |
| `signatureImageUrl` | `string` | Yes | Signature image file URL |
| `pageIndex` | `number` | Yes | Page index (0-based) |
| `x` | `number` | Yes | X position (normalized 0–1) |
| `y` | `number` | Yes | Y position (normalized 0–1) |
| `width` | `number` | Yes | Width (normalized 0–1) |
| `height` | `number` | Yes | Height (normalized 0–1) |
| `placements` | `Array<{ pageIndex, x, y, width, height }>` | No | Multi-page placements |

**Returns:** `{ pdfUrl: string }`

```ts
const result = await Neurosign.addSignatureImage({
  pdfUrl: pdf.pdfUrl,
  signatureImageUrl: signatureUri,
  pageIndex: 0,
  x: 0.6, y: 0.85, width: 0.3, height: 0.1,
  placements: [
    { pageIndex: 0, x: 0.6, y: 0.85, width: 0.3, height: 0.1 },
    { pageIndex: 1, x: 0.6, y: 0.85, width: 0.3, height: 0.1 },
  ],
});
```

---

#### `signPdf(options)`

Apply a PAdES-B-B digital signature to a PDF.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `pdfUrl` | `string` | Yes | PDF file URL |
| `certificateType` | `string` | Yes | `"selfSigned"` or `"keychain"` |
| `certificatePath` | `string` | No | Path to `.p12`/`.pfx` file |
| `certificatePassword` | `string` | No | Password for the certificate file |
| `keychainAlias` | `string` | No | Alias of certificate in keychain/keystore |
| `reason` | `string` | No | Signing reason |
| `location` | `string` | No | Signing location |
| `contactInfo` | `string` | No | Signer contact info |

**Returns:** `{ pdfUrl: string, signatureValid: boolean, signerName: string, signedAt: string }`

```ts
const signed = await Neurosign.signPdf({
  pdfUrl: pdf.pdfUrl,
  certificateType: 'keychain',
  keychainAlias: 'my-cert',
  reason: 'Approval',
  location: 'Kyiv',
});
```

---

#### `verifySignature(pdfUrl)`

Verify all digital signatures in a PDF document.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `pdfUrl` | `string` | Yes | PDF file URL to verify |

**Returns:** `{ signed: boolean, signatures: Array<{ signerName, signedAt, valid, trusted, reason }> }`

```ts
const result = await Neurosign.verifySignature(pdfUrl);
if (result.signed) {
  result.signatures.forEach(sig => {
    console.log(`${sig.signerName}: valid=${sig.valid}`);
  });
}
```

---

#### `renderPdfPage(options)`

Render a single PDF page to a PNG image.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `pdfUrl` | `string` | Yes | PDF file URL |
| `pageIndex` | `number` | Yes | Page index (0-based) |
| `width` | `number` | Yes | Output width in points |
| `height` | `number` | Yes | Output height in points |

**Returns:** `{ imageUrl: string, pageWidth: number, pageHeight: number, pageCount: number }`

```ts
const page = await Neurosign.renderPdfPage({
  pdfUrl: pdf.pdfUrl,
  pageIndex: 0,
  width: 400,
  height: 560,
});
```

---

#### `importCertificate(options)`

Import a PKCS#12 (`.p12`/`.pfx`) certificate into the device keychain/keystore.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `certificatePath` | `string` | Yes | Path to `.p12`/`.pfx` file |
| `password` | `string` | Yes | Certificate password |
| `alias` | `string` | Yes | Alias for storage |

**Returns:** `{ alias, subject, issuer, validFrom, validTo, serialNumber }`

```ts
const cert = await Neurosign.importCertificate({
  certificatePath: fileUri,
  password: 'secret',
  alias: 'work-cert',
});
```

---

#### `generateSelfSignedCertificate(options)`

Generate a self-signed X.509 certificate and store it in the keychain/keystore.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `commonName` | `string` | Yes | Certificate CN |
| `organization` | `string` | No | Organization name |
| `country` | `string` | No | Country code (e.g. `"UA"`) |
| `validityDays` | `number` | No | Validity period in days |
| `alias` | `string` | Yes | Alias for storage |
| `keyAlgorithm` | `string` | No | `"RSA"` (default) or `"EC"` |

**Returns:** `{ alias, subject, issuer, validFrom, validTo, serialNumber }`

```ts
const cert = await Neurosign.generateSelfSignedCertificate({
  commonName: 'John Doe',
  organization: 'Acme Corp',
  country: 'UA',
  validityDays: 365,
  alias: 'john-cert',
});
```

---

#### `listCertificates()`

List all Neurosign-managed certificates in the device keychain/keystore.

**Returns:** `Array<{ alias, subject, issuer, validFrom, validTo, serialNumber }>`

```ts
const certs = await Neurosign.listCertificates();
certs.forEach(c => console.log(c.alias, c.subject));
```

---

#### `deleteCertificate(alias)`

Delete a certificate from the keychain/keystore.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `alias` | `string` | Yes | Certificate alias |

**Returns:** `boolean`

```ts
await Neurosign.deleteCertificate('old-cert');
```

---

#### `prepareForExternalSigning(options)`

Prepare a PDF for external (server-side) signing. Returns a hash to be signed remotely.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `pdfUrl` | `string` | Yes | PDF file URL |
| `reason` | `string` | No | Signing reason |
| `location` | `string` | No | Signing location |
| `contactInfo` | `string` | No | Contact info |

**Returns:** `{ preparedPdfUrl: string, hash: string, hashAlgorithm: string }`

```ts
const prepared = await Neurosign.prepareForExternalSigning({
  pdfUrl: pdf.pdfUrl,
  reason: 'Remote signing',
});
// Send prepared.hash to your signing server
```

---

#### `completeExternalSigning(options)`

Embed an externally-produced CMS/PKCS#7 signature into a prepared PDF.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `preparedPdfUrl` | `string` | Yes | URL from `prepareForExternalSigning` |
| `signature` | `string` | Yes | Base64-encoded DER CMS SignedData |

**Returns:** `{ pdfUrl: string }`

```ts
const result = await Neurosign.completeExternalSigning({
  preparedPdfUrl: prepared.preparedPdfUrl,
  signature: base64CmsFromServer,
});
```

---

#### `cleanupTempFiles()`

Remove all temporary files created by Neurosign.

**Returns:** `boolean`

```ts
await Neurosign.cleanupTempFiles();
```

---

### `SignaturePad` Component

A native view for drawing signatures. Uses PencilKit on iOS with pressure sensitivity.

```tsx
import { SignaturePad, type SignaturePadRef } from 'react-native-neurosign';

const signatureRef = useRef<SignaturePadRef>(null);

<SignaturePad
  ref={signatureRef}
  strokeColor="#1a1a2e"
  strokeWidth={2}
  minStrokeWidth={1}
  maxStrokeWidth={5}
  backgroundColor="#FFFFFF"
  onDrawingChanged={(hasDrawing) => setHasDrawing(hasDrawing)}
  onSignatureExported={(imageUrl) => setSignatureImage(imageUrl)}
  style={{ width: '100%', height: 200 }}
/>

// Controls
signatureRef.current?.clear();
signatureRef.current?.undo();
signatureRef.current?.redo();
signatureRef.current?.exportSignature('png', 90);
```

#### Props

| Prop | Type | Default | Description |
|------|------|---------|-------------|
| `strokeColor` | `string` | `"#000000"` | Ink color (hex) |
| `strokeWidth` | `number` | `2` | Base stroke width |
| `backgroundColor` | `string` | `"#FFFFFF"` | Canvas background |
| `minStrokeWidth` | `number` | `1` | Min stroke width (pressure) |
| `maxStrokeWidth` | `number` | `5` | Max stroke width (pressure) |
| `onDrawingChanged` | `(hasDrawing: boolean) => void` | — | Drawing state change callback |
| `onSignatureExported` | `(imageUrl: string) => void` | — | Export result callback |
| `style` | `StyleProp<ViewStyle>` | — | View style |

#### Ref Methods

| Method | Description |
|--------|-------------|
| `clear()` | Clear the canvas |
| `undo()` | Undo last stroke |
| `redo()` | Redo undone stroke |
| `exportSignature(format?, quality?)` | Export as `'png'` or `'svg'`, quality 0–100 |

---

### `SignaturePlacement` Component

A native view that renders a PDF page and lets the user drag & pinch-to-resize a signature overlay to choose where to place it.

```tsx
import { SignaturePlacement, type SignaturePlacementRef } from 'react-native-neurosign';

const placementRef = useRef<SignaturePlacementRef>(null);

<SignaturePlacement
  ref={placementRef}
  pdfUrl={pdfUrl}
  signatureImageUrl={signatureImageUrl}
  pageIndex={0}
  defaultPositionX={-1}
  defaultPositionY={-1}
  backgroundColor="#f0f0f0"
  signature={{
    borderColor: '#E94560',
    borderWidth: 2,
    cornerSize: 14,
    cornerWidth: 3,
  }}
  onPlacementConfirmed={(placement) => {
    console.log(placement); // { pageIndex, x, y, width, height }
  }}
  onPageCount={(count) => setPageCount(count)}
  style={{ flex: 1 }}
/>

// Confirm or reset
placementRef.current?.confirm();
placementRef.current?.reset();
```

#### Props

| Prop | Type | Default | Description |
|------|------|---------|-------------|
| `pdfUrl` | `string` | — | PDF file URL |
| `signatureImageUrl` | `string` | — | Signature image file URL |
| `pageIndex` | `number` | `0` | Page to display (0-based) |
| `defaultPositionX` | `number` | `-1` | Default X (0–1, or -1 for center) |
| `defaultPositionY` | `number` | `-1` | Default Y (0–1, or -1 for center) |
| `backgroundColor` | `string` | — | Background color (hex) |
| `signature` | `SignatureStyle` | — | Overlay border styling |
| `onPlacementConfirmed` | `(placement) => void` | — | Confirmed placement callback |
| `onPageCount` | `(count: number) => void` | — | Page count callback |
| `style` | `StyleProp<ViewStyle>` | — | View style |

#### `SignatureStyle`

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `borderColor` | `string` | `"#E94560"` | Dashed border & corner color |
| `borderWidth` | `number` | `2` | Border stroke width |
| `borderPadding` | `number` | `0` | Padding around signature |
| `cornerSize` | `number` | `14` | Corner handle length |
| `cornerWidth` | `number` | `3` | Corner handle stroke width |
| `borderRadius` | `number` | `0` | Border corner radius |

#### Ref Methods

| Method | Description |
|--------|-------------|
| `confirm()` | Confirm the current placement and fire `onPlacementConfirmed` |
| `reset()` | Reset to default position and size |

---

## Error Handling

All methods throw `NeurosignError` on failure. Use the `isNeurosignError` type guard:

```ts
import Neurosign, { isNeurosignError } from 'react-native-neurosign';

try {
  await Neurosign.signPdf({ ... });
} catch (error) {
  if (isNeurosignError(error)) {
    switch (error.code) {
      case 'CERTIFICATE_ERROR':
        // Handle certificate issues
        break;
      case 'SIGNATURE_FAILED':
        // Handle signing failure
        break;
    }
  }
}
```

### Error Codes

| Code | Description |
|------|-------------|
| `PDF_GENERATION_FAILED` | Failed to generate PDF from images |
| `SIGNATURE_FAILED` | Failed to apply digital signature |
| `CERTIFICATE_ERROR` | Certificate import/generation/access error |
| `VERIFICATION_FAILED` | Signature verification error |
| `INVALID_INPUT` | Invalid parameters provided |
| `CLEANUP_FAILED` | Failed to clean up temp files |
| `EXTERNAL_SIGNING_FAILED` | External signing flow error |

## Platform Notes

### iOS
- Signature drawing uses **PencilKit** with full Apple Pencil pressure sensitivity
- Certificate storage uses **iOS Keychain** via Security.framework
- PDF signing uses **OpenSSL** (bundled via `OpenSSL-Universal` pod)
- Minimum deployment target: **iOS 16.0**

### Android
- Signature drawing uses **Canvas** with custom touch handling
- Certificate storage uses **Android KeyStore**
- PDF signing uses **BouncyCastle** (`bcprov-jdk18on`, `bcpkix-jdk18on`)
- Minimum SDK: **24** (Android 7.0)

## License

MIT
