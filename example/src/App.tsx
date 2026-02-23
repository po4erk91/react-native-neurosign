import { useState, useCallback, useRef } from 'react';
import {
  Text,
  View,
  StyleSheet,
  TouchableOpacity,
  Image,
  ScrollView,
  SafeAreaView,
  Alert,
  Dimensions,
  ActivityIndicator,
  Platform,
  StatusBar,
  Modal,
  TextInput,
} from 'react-native';
import {
  Neurosign,
  SignaturePad,
  SignaturePlacement,
  type SignaturePadRef,
  type SignaturePlacementRef,
} from 'react-native-neurosign';
import { launchImageLibrary } from 'react-native-image-picker';
import {
  pick,
  types,
  isErrorWithCode,
  errorCodes,
} from '@react-native-documents/picker';
import Share from 'react-native-share';

const { width: SCREEN_WIDTH } = Dimensions.get('window');

type Screen =
  | 'home'
  | 'images'
  | 'pdf'
  | 'signature'
  | 'sign'
  | 'placement'
  | 'verify'
  | 'certificates'
  | 'documents';

type DocumentItem = {
  id: number;
  name: string;
  pdfUrl: string;
  createdAt: Date;
  signed: boolean;
  signedPdfUrl: string | null;
  thumbnailUrl: string | null;
};

type CertificateInfo = {
  alias: string;
  subject: string;
  issuer: string;
  validFrom: string;
  validTo: string;
  serialNumber: string;
};

export default function App() {
  const [screen, setScreen] = useState<Screen>('home');
  const [imageUrls, setImageUrls] = useState<string[]>([]);
  const [pdfUrl, setPdfUrl] = useState<string | null>(null);
  const [signatureImageUrl, setSignatureImageUrl] = useState<string | null>(
    null
  );
  const [signedPdfUrl, setSignedPdfUrl] = useState<string | null>(null);
  const [hasDrawing, setHasDrawing] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  const [loadingText, setLoadingText] = useState('');
  const [certificates, setCertificates] = useState<CertificateInfo[]>([]);
  const [verifyResult, setVerifyResult] = useState<{
    signed: boolean;
    signatures: Array<{
      signerName: string;
      signedAt: string;
      valid: boolean;
      trusted: boolean;
      reason: string;
    }>;
  } | null>(null);

  const [documents, setDocuments] = useState<DocumentItem[]>([]);
  const [activeDocumentId, setActiveDocumentId] = useState<number | null>(null);
  const docIdCounter = useRef(0);

  const signatureRef = useRef<SignaturePadRef>(null);
  const placementRef = useRef<SignaturePlacementRef>(null);
  const [placementPageIndex, setPlacementPageIndex] = useState(0);
  const [placementPageCount, setPlacementPageCount] = useState(1);
  const [collectedPlacements, setCollectedPlacements] = useState<
    Map<
      number,
      { pageIndex: number; x: number; y: number; width: number; height: number }
    >
  >(new Map());

  // Certificate picker state
  const [showCertPicker, setShowCertPicker] = useState(false);
  const [pendingSignAction, setPendingSignAction] = useState<{
    pdfUrl: string;
    documentId?: number;
  } | null>(null);

  // Import .pfx modal state
  const [showImportModal, setShowImportModal] = useState(false);
  const [importFileUri, setImportFileUri] = useState<string | null>(null);
  const [importFileName, setImportFileName] = useState('');
  const [importPassword, setImportPassword] = useState('');
  const [importAlias, setImportAlias] = useState('');

  // ── Step 1: Pick images ──

  const handlePickImages = useCallback(async () => {
    try {
      const result = await launchImageLibrary({
        mediaType: 'photo',
        selectionLimit: 0, // unlimited
      });

      if (result.didCancel) return;

      if (result.assets && result.assets.length > 0) {
        const urls = result.assets
          .map((asset) => asset.uri)
          .filter((uri): uri is string => !!uri);
        setImageUrls(urls);
        setScreen('images');
      }
    } catch (error: any) {
      Alert.alert('Error', error.message || 'Failed to pick images');
    }
  }, []);

  // ── Step 2: Generate PDF ──

  const handleGeneratePdf = useCallback(async () => {
    if (imageUrls.length === 0) {
      Alert.alert('Error', 'No images selected');
      return;
    }

    try {
      setIsLoading(true);
      setLoadingText('Generating PDF...');

      const docId = ++docIdCounter.current;
      const docName = `neurosign-demo-${docId}`;

      const result = await Neurosign.generatePdf({
        imageUrls,
        fileName: docName,
        pageSize: 'A4',
        pageMargin: 20,
        quality: 90,
      });

      setPdfUrl(result.pdfUrl);

      // Generate thumbnail and create document entry
      let thumbnailUrl: string | null = null;
      try {
        const thumb = await Neurosign.renderPdfPage({
          pdfUrl: result.pdfUrl,
          pageIndex: 0,
          width: 200,
          height: 280,
        });
        thumbnailUrl = thumb.imageUrl;
      } catch {}

      const newDoc: DocumentItem = {
        id: docId,
        name: docName,
        pdfUrl: result.pdfUrl,
        createdAt: new Date(),
        signed: false,
        signedPdfUrl: null,
        thumbnailUrl,
      };
      setDocuments((prev) => [newDoc, ...prev]);
      setActiveDocumentId(docId);

      Alert.alert(
        'PDF Generated',
        `Created ${result.pageCount} page PDF\n${result.pdfUrl}`
      );
      setScreen('pdf');
    } catch (error: any) {
      Alert.alert('PDF Error', error.message || 'Failed to generate PDF');
    } finally {
      setIsLoading(false);
    }
  }, [imageUrls]);

  // ── Step 3: Export signature ──

  const handleExportSignature = useCallback(() => {
    if (!hasDrawing) {
      Alert.alert('Error', 'Please draw your signature first');
      return;
    }
    signatureRef.current?.exportSignature('png', 90);
  }, [hasDrawing]);

  const handleSignatureExported = useCallback(
    (imageUrl: string) => {
      setSignatureImageUrl(imageUrl);
      Alert.alert('Signature Exported', 'Signature saved as image');
      if (pdfUrl) {
        setScreen('sign');
      }
    },
    [pdfUrl]
  );

  // ── Step 4: Place visual signature on PDF (interactive) ──

  const handleStartPlacement = useCallback(() => {
    if (!pdfUrl || !signatureImageUrl) {
      Alert.alert('Error', 'PDF and signature image required');
      return;
    }
    setPlacementPageIndex(0);
    setPlacementPageCount(1);
    setCollectedPlacements(new Map());
    setScreen('placement');
  }, [pdfUrl, signatureImageUrl]);

  // Store placement for current page (used for both single and multi-page)
  const handlePlacementAdd = useCallback(
    (placement: {
      pageIndex: number;
      x: number;
      y: number;
      width: number;
      height: number;
    }) => {
      setCollectedPlacements((prev) => {
        const next = new Map(prev);
        next.set(placement.pageIndex, placement);
        return next;
      });
    },
    []
  );

  // Apply all collected placements at once
  const handleApplyAllPlacements = useCallback(async () => {
    if (!pdfUrl || !signatureImageUrl || collectedPlacements.size === 0) return;

    try {
      setScreen('sign');
      setIsLoading(true);
      setLoadingText('Adding signatures to PDF...');

      const placements = Array.from(collectedPlacements.values());
      const first = placements[0]!;

      const result = await Neurosign.addSignatureImage({
        pdfUrl,
        signatureImageUrl,
        pageIndex: first.pageIndex,
        x: first.x,
        y: first.y,
        width: first.width,
        height: first.height,
        placements,
      });

      setPdfUrl(result.pdfUrl);

      if (activeDocumentId != null) {
        setDocuments((prev) =>
          prev.map((d) =>
            d.id === activeDocumentId ? { ...d, pdfUrl: result.pdfUrl } : d
          )
        );
      }

      setCollectedPlacements(new Map());
      Alert.alert(
        'Signatures Added',
        `Visual signature placed on ${placements.length} page(s)`
      );
    } catch (error: any) {
      Alert.alert('Error', error.message || 'Failed to add signature');
    } finally {
      setIsLoading(false);
    }
  }, [pdfUrl, signatureImageUrl, collectedPlacements, activeDocumentId]);

  // ── Step 5: Generate self-signed certificate ──

  const handleGenerateCertificate = useCallback(async () => {
    try {
      setIsLoading(true);
      setLoadingText('Generating certificate...');

      const cert = await Neurosign.generateSelfSignedCertificate({
        commonName: 'Neurosign Demo User',
        organization: 'Neurosign Demo',
        country: 'UA',
        validityDays: 365,
        alias: 'demo-cert',
      });

      Alert.alert(
        'Certificate Generated',
        `Subject: ${cert.subject}\nValid until: ${cert.validTo}`
      );
      await loadCertificates();
    } catch (error: any) {
      Alert.alert('Error', error.message || 'Failed to generate certificate');
    } finally {
      setIsLoading(false);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const loadCertificates = useCallback(async () => {
    try {
      const certs = await Neurosign.listCertificates();
      setCertificates(certs);
    } catch (error: any) {
      console.warn('Failed to load certificates:', error.message);
    }
  }, []);

  // ── Step 6: Sign PDF with PAdES ──

  const performSign = useCallback(
    async (
      targetPdfUrl: string,
      documentId: number | undefined,
      selectedCert: CertificateInfo | null
    ) => {
      try {
        setIsLoading(true);
        setLoadingText('Signing PDF with PAdES...');

        const signOptions: Parameters<typeof Neurosign.signPdf>[0] = {
          pdfUrl: targetPdfUrl,
          reason: 'Document signature',
          location: 'Neurosign Example App',
          contactInfo: 'demo@neurosign.dev',
          certificateType: selectedCert ? 'keychain' : 'selfSigned',
          ...(selectedCert ? { keychainAlias: selectedCert.alias } : {}),
        };

        const result = await Neurosign.signPdf(signOptions);

        if (documentId != null) {
          setDocuments((prev) =>
            prev.map((d) =>
              d.id === documentId
                ? { ...d, signed: true, signedPdfUrl: result.pdfUrl }
                : d
            )
          );
        }

        if (targetPdfUrl === pdfUrl) {
          setSignedPdfUrl(result.pdfUrl);
        }

        Alert.alert(
          'PDF Signed',
          `Signer: ${result.signerName}\nSigned at: ${result.signedAt}\nValid: ${result.signatureValid}`
        );
      } catch (error: any) {
        Alert.alert('Sign Error', error.message || 'Failed to sign PDF');
      } finally {
        setIsLoading(false);
      }
    },
    [pdfUrl]
  );

  const requestSign = useCallback(
    async (targetPdfUrl: string, documentId?: number) => {
      try {
        const certs = await Neurosign.listCertificates();
        setCertificates(certs);

        if (certs.length === 0) {
          // No certs — go straight to self-signed
          performSign(targetPdfUrl, documentId, null);
        } else {
          setPendingSignAction({ pdfUrl: targetPdfUrl, documentId });
          setShowCertPicker(true);
        }
      } catch {
        // Failed to load certs — fall back to self-signed
        performSign(targetPdfUrl, documentId, null);
      }
    },
    [performSign]
  );

  const handleCertSelected = useCallback(
    (cert: CertificateInfo | null) => {
      setShowCertPicker(false);
      if (!pendingSignAction) return;
      performSign(pendingSignAction.pdfUrl, pendingSignAction.documentId, cert);
      setPendingSignAction(null);
    },
    [pendingSignAction, performSign]
  );

  // ── Import .pfx ──

  const handleImportPfx = useCallback(async () => {
    try {
      const [result] = await pick({ type: [types.allFiles] });
      if (!result?.uri) return;
      setImportFileUri(result.uri);
      setImportFileName(result.name ?? 'certificate.pfx');
      setShowImportModal(true);
    } catch (error: any) {
      if (
        isErrorWithCode(error) &&
        error.code === errorCodes.OPERATION_CANCELED
      )
        return;
      Alert.alert('Error', error.message || 'Failed to pick file');
    }
  }, []);

  const handleImportConfirm = useCallback(async () => {
    if (!importFileUri) return;
    try {
      setShowImportModal(false);
      setIsLoading(true);
      setLoadingText('Importing certificate...');

      const alias = importAlias.trim() || `imported-${Date.now()}`;
      await Neurosign.importCertificate({
        certificatePath: importFileUri,
        password: importPassword,
        alias,
      });

      Alert.alert('Success', `Certificate imported as "${alias}"`);
      setImportPassword('');
      setImportAlias('');
      setImportFileUri(null);
      await loadCertificates();
    } catch (error: any) {
      Alert.alert(
        'Import Error',
        error.message || 'Failed to import certificate'
      );
    } finally {
      setIsLoading(false);
    }
  }, [importFileUri, importPassword, importAlias, loadCertificates]);

  // ── Step 7: Verify signature ──

  const handleVerifySignature = useCallback(async () => {
    const urlToVerify = signedPdfUrl || pdfUrl;
    if (!urlToVerify) {
      Alert.alert('Error', 'No PDF to verify');
      return;
    }

    try {
      setIsLoading(true);
      setLoadingText('Verifying signatures...');

      const result = await Neurosign.verifySignature(urlToVerify);
      setVerifyResult(result);
      setScreen('verify');
    } catch (error: any) {
      Alert.alert('Verify Error', error.message || 'Failed to verify');
    } finally {
      setIsLoading(false);
    }
  }, [signedPdfUrl, pdfUrl]);

  // ── Document actions (from documents list) ──

  const handleDocumentSign = useCallback(
    (doc: DocumentItem) => {
      requestSign(doc.pdfUrl, doc.id);
    },
    [requestSign]
  );

  const handleDocumentVerify = useCallback(async (doc: DocumentItem) => {
    try {
      setIsLoading(true);
      setLoadingText('Verifying signatures...');

      const urlToVerify = doc.signedPdfUrl || doc.pdfUrl;
      const result = await Neurosign.verifySignature(urlToVerify);
      setVerifyResult(result);
      setScreen('verify');
    } catch (error: any) {
      Alert.alert('Verify Error', error.message || 'Failed to verify');
    } finally {
      setIsLoading(false);
    }
  }, []);

  const handleDocumentShare = useCallback(async (doc: DocumentItem) => {
    try {
      const urlToShare = doc.signedPdfUrl || doc.pdfUrl;
      const shareName = doc.signed
        ? `${doc.name}_signed.pdf`
        : `${doc.name}.pdf`;
      await Share.open({
        url: urlToShare,
        type: 'application/pdf',
        filename: shareName,
        title: shareName,
        subject: shareName,
      });
    } catch (error: any) {
      // User cancelled share sheet — not an error
      if (error?.message !== 'User did not share') {
        Alert.alert('Share Error', error.message || 'Failed to share');
      }
    }
  }, []);

  // ── Cleanup ──

  const handleCleanup = useCallback(async () => {
    try {
      await Neurosign.cleanupTempFiles();
      setImageUrls([]);
      setPdfUrl(null);
      setSignatureImageUrl(null);
      setSignedPdfUrl(null);
      setVerifyResult(null);
      setHasDrawing(false);
      setCertificates([]);
      setDocuments([]);
      setActiveDocumentId(null);
      setScreen('home');
      Alert.alert('Cleanup', 'Temporary files cleaned up');
    } catch (error: any) {
      Alert.alert('Error', error.message || 'Cleanup failed');
    }
  }, []);

  // ── Modals (always rendered, on top of any screen) ──

  const modals = (
    <>
      {/* Certificate Picker Modal */}
      <Modal
        visible={showCertPicker}
        transparent
        animationType="slide"
        onRequestClose={() => setShowCertPicker(false)}
      >
        <View style={styles.modalOverlay}>
          <View style={styles.modalContent}>
            <Text style={styles.modalTitle}>Select Certificate</Text>
            <ScrollView style={{ maxHeight: 300 }}>
              {certificates.map((cert, index) => (
                <TouchableOpacity
                  key={index}
                  style={styles.certPickerItem}
                  onPress={() => handleCertSelected(cert)}
                >
                  <Text style={styles.certPickerAlias}>{cert.alias}</Text>
                  <Text style={styles.certPickerDetail}>{cert.subject}</Text>
                  <Text style={styles.certPickerDetail}>
                    Valid: {cert.validFrom} — {cert.validTo}
                  </Text>
                </TouchableOpacity>
              ))}
            </ScrollView>
            <TouchableOpacity
              style={[styles.buttonSecondary, { marginTop: 12 }]}
              onPress={() => handleCertSelected(null)}
            >
              <Text style={styles.buttonSecondaryText}>
                Generate New Self-Signed
              </Text>
            </TouchableOpacity>
            <TouchableOpacity
              style={{ marginTop: 12, alignItems: 'center', padding: 8 }}
              onPress={() => setShowCertPicker(false)}
            >
              <Text style={styles.modalCancel}>Cancel</Text>
            </TouchableOpacity>
          </View>
        </View>
      </Modal>

      {/* Import .pfx Modal */}
      <Modal
        visible={showImportModal}
        transparent
        animationType="fade"
        onRequestClose={() => setShowImportModal(false)}
      >
        <View style={styles.modalOverlay}>
          <View style={styles.modalContent}>
            <Text style={styles.modalTitle}>Import Certificate</Text>
            <Text style={styles.modalSubtitle}>{importFileName}</Text>
            <TextInput
              style={styles.modalInput}
              placeholder="Password"
              placeholderTextColor="#C7C7CC"
              secureTextEntry
              value={importPassword}
              onChangeText={setImportPassword}
              autoCapitalize="none"
            />
            <TextInput
              style={styles.modalInput}
              placeholder="Alias (optional)"
              placeholderTextColor="#C7C7CC"
              value={importAlias}
              onChangeText={setImportAlias}
              autoCapitalize="none"
            />
            <View style={styles.modalActions}>
              <TouchableOpacity
                style={{ padding: 8 }}
                onPress={() => {
                  setShowImportModal(false);
                  setImportPassword('');
                  setImportAlias('');
                }}
              >
                <Text style={styles.modalCancel}>Cancel</Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={{ padding: 8 }}
                onPress={handleImportConfirm}
              >
                <Text style={styles.modalConfirm}>Import</Text>
              </TouchableOpacity>
            </View>
          </View>
        </View>
      </Modal>
    </>
  );

  // ── Loading overlay ──

  if (isLoading) {
    return (
      <>
        <SafeAreaView style={styles.container}>
          <View style={styles.loadingContainer}>
            <ActivityIndicator size="large" color="#007AFF" />
            <Text style={styles.loadingText}>{loadingText}</Text>
          </View>
        </SafeAreaView>
        {modals}
      </>
    );
  }

  // ── Screen content ──

  const renderScreen = () => {
    if (screen === 'home') {
      return (
        <SafeAreaView style={styles.container}>
          <ScrollView contentContainerStyle={styles.scrollContent}>
            <Text style={styles.title}>Neurosign</Text>
            <Text style={styles.subtitle}>
              PDF Generation & Digital Signing
            </Text>

            <View style={styles.section}>
              <Text style={styles.sectionTitle}>Full Workflow</Text>

              <TouchableOpacity
                style={styles.button}
                onPress={handlePickImages}
              >
                <Text style={styles.buttonText}>1. Pick Images</Text>
                <Text style={styles.buttonHint}>
                  Select images for PDF generation
                </Text>
              </TouchableOpacity>

              <TouchableOpacity
                style={styles.button}
                onPress={() => setScreen('signature')}
              >
                <Text style={styles.buttonText}>2. Draw Signature</Text>
                <Text style={styles.buttonHint}>
                  Use native SignaturePad component
                </Text>
              </TouchableOpacity>

              <TouchableOpacity
                style={[styles.button, !pdfUrl && styles.buttonDisabled]}
                onPress={pdfUrl ? () => requestSign(pdfUrl) : undefined}
              >
                <Text style={styles.buttonText}>3. Sign PDF (PAdES)</Text>
                <Text style={styles.buttonHint}>
                  {pdfUrl
                    ? 'Apply cryptographic signature'
                    : 'Generate PDF first'}
                </Text>
              </TouchableOpacity>

              <TouchableOpacity
                style={[
                  styles.button,
                  !signedPdfUrl && !pdfUrl && styles.buttonDisabled,
                ]}
                onPress={
                  signedPdfUrl || pdfUrl ? handleVerifySignature : undefined
                }
              >
                <Text style={styles.buttonText}>4. Verify Signature</Text>
                <Text style={styles.buttonHint}>
                  {signedPdfUrl || pdfUrl
                    ? 'Check signature validity'
                    : 'Sign a PDF first'}
                </Text>
              </TouchableOpacity>
            </View>

            <View style={styles.section}>
              <Text style={styles.sectionTitle}>Certificates</Text>

              <TouchableOpacity
                style={styles.buttonSecondary}
                onPress={handleGenerateCertificate}
              >
                <Text style={styles.buttonSecondaryText}>
                  Generate Self-Signed Certificate
                </Text>
              </TouchableOpacity>

              <TouchableOpacity
                style={styles.buttonSecondary}
                onPress={() => {
                  loadCertificates();
                  setScreen('certificates');
                }}
              >
                <Text style={styles.buttonSecondaryText}>
                  View Certificates
                </Text>
              </TouchableOpacity>
            </View>

            {documents.length > 0 && (
              <View style={styles.section}>
                <TouchableOpacity
                  style={styles.button}
                  onPress={() => setScreen('documents')}
                >
                  <Text style={styles.buttonText}>
                    Documents ({documents.length})
                  </Text>
                  <Text style={styles.buttonHint}>
                    View, sign, verify, and share your PDFs
                  </Text>
                </TouchableOpacity>
              </View>
            )}

            <View style={styles.section}>
              <Text style={styles.sectionTitle}>Status</Text>
              <View style={styles.statusRow}>
                <Text style={styles.statusLabel}>Images:</Text>
                <Text style={styles.statusValue}>
                  {imageUrls.length > 0
                    ? `${imageUrls.length} selected`
                    : 'None'}
                </Text>
              </View>
              <View style={styles.statusRow}>
                <Text style={styles.statusLabel}>PDF:</Text>
                <Text style={styles.statusValue}>
                  {pdfUrl ? 'Generated' : 'None'}
                </Text>
              </View>
              <View style={styles.statusRow}>
                <Text style={styles.statusLabel}>Signature:</Text>
                <Text style={styles.statusValue}>
                  {signatureImageUrl ? 'Exported' : 'None'}
                </Text>
              </View>
              <View style={styles.statusRow}>
                <Text style={styles.statusLabel}>Signed PDF:</Text>
                <Text style={styles.statusValue}>
                  {signedPdfUrl ? 'Signed' : 'None'}
                </Text>
              </View>
            </View>

            {(pdfUrl || signedPdfUrl) && (
              <TouchableOpacity
                style={styles.buttonDanger}
                onPress={handleCleanup}
              >
                <Text style={styles.buttonDangerText}>Cleanup Temp Files</Text>
              </TouchableOpacity>
            )}

            <Text style={styles.footer}>
              react-native-neurosign v0.1.0 | {Platform.OS} | {Platform.Version}
            </Text>
          </ScrollView>
        </SafeAreaView>
      );
    }

    // ── Images Screen ──

    if (screen === 'images') {
      return (
        <SafeAreaView style={styles.container}>
          <View style={styles.header}>
            <TouchableOpacity onPress={() => setScreen('home')}>
              <Text style={styles.backButton}>Back</Text>
            </TouchableOpacity>
            <Text style={styles.headerTitle}>
              Selected Images ({imageUrls.length})
            </Text>
            <TouchableOpacity onPress={handleGeneratePdf}>
              <Text style={styles.actionButton}>Generate PDF</Text>
            </TouchableOpacity>
          </View>

          <ScrollView contentContainerStyle={styles.imageGrid}>
            {imageUrls.map((url, index) => (
              <View key={index} style={styles.imageCard}>
                <Image
                  source={{ uri: url }}
                  style={styles.thumbnail}
                  resizeMode="cover"
                />
                <Text style={styles.imageLabel}>Page {index + 1}</Text>
              </View>
            ))}
          </ScrollView>
        </SafeAreaView>
      );
    }

    // ── PDF Screen ──

    if (screen === 'pdf') {
      return (
        <SafeAreaView style={styles.container}>
          <View style={styles.header}>
            <TouchableOpacity onPress={() => setScreen('home')}>
              <Text style={styles.backButton}>Back</Text>
            </TouchableOpacity>
            <Text style={styles.headerTitle}>PDF Generated</Text>
            <View style={{ width: 50 }} />
          </View>

          <ScrollView contentContainerStyle={styles.scrollContent}>
            <View style={styles.successCard}>
              <Text style={styles.successIcon}>PDF</Text>
              <Text style={styles.successTitle}>Document Created</Text>
              <Text style={styles.successSubtitle}>
                {imageUrls.length} pages | A4 format
              </Text>
              <Text style={styles.fileUrl} numberOfLines={2}>
                {pdfUrl}
              </Text>
            </View>

            <Text style={styles.sectionTitle}>Next Steps</Text>

            <TouchableOpacity
              style={styles.button}
              onPress={() => setScreen('signature')}
            >
              <Text style={styles.buttonText}>Draw Signature</Text>
            </TouchableOpacity>

            {signatureImageUrl && (
              <TouchableOpacity
                style={styles.button}
                onPress={handleStartPlacement}
              >
                <Text style={styles.buttonText}>Place Signature on PDF</Text>
                <Text style={styles.buttonHint}>
                  Drag and resize on document preview
                </Text>
              </TouchableOpacity>
            )}

            <TouchableOpacity
              style={styles.button}
              onPress={() =>
                pdfUrl && requestSign(pdfUrl, activeDocumentId ?? undefined)
              }
            >
              <Text style={styles.buttonText}>Sign with PAdES</Text>
            </TouchableOpacity>

            <TouchableOpacity
              style={styles.button}
              onPress={handleVerifySignature}
            >
              <Text style={styles.buttonText}>Verify Signatures</Text>
            </TouchableOpacity>
          </ScrollView>
        </SafeAreaView>
      );
    }

    // ── Signature Screen ──

    if (screen === 'signature') {
      return (
        <SafeAreaView style={styles.container}>
          <View style={styles.header}>
            <TouchableOpacity
              onPress={() => setScreen(pdfUrl ? 'pdf' : 'home')}
            >
              <Text style={styles.backButton}>Back</Text>
            </TouchableOpacity>
            <Text style={styles.headerTitle}>Draw Signature</Text>
            <TouchableOpacity onPress={handleExportSignature}>
              <Text
                style={[
                  styles.actionButton,
                  !hasDrawing && styles.actionButtonDisabled,
                ]}
              >
                Export
              </Text>
            </TouchableOpacity>
          </View>

          <View style={styles.signaturePadContainer}>
            <Text style={styles.signatureHint}>
              Draw your signature below
              {Platform.OS === 'ios' ? ' (Apple Pencil supported)' : ''}
            </Text>

            <View style={styles.signaturePadWrapper}>
              <SignaturePad
                ref={signatureRef}
                strokeColor="#1a1a2e"
                strokeWidth={2}
                minStrokeWidth={1}
                maxStrokeWidth={5}
                backgroundColor="#FFFFFF"
                onDrawingChanged={setHasDrawing}
                onSignatureExported={handleSignatureExported}
                style={styles.signaturePad}
              />
            </View>

            <View style={styles.signatureActions}>
              <TouchableOpacity
                style={styles.buttonSmall}
                onPress={() => signatureRef.current?.undo()}
              >
                <Text style={styles.buttonSmallText}>Undo</Text>
              </TouchableOpacity>

              <TouchableOpacity
                style={styles.buttonSmall}
                onPress={() => signatureRef.current?.redo()}
              >
                <Text style={styles.buttonSmallText}>Redo</Text>
              </TouchableOpacity>

              <TouchableOpacity
                style={[styles.buttonSmall, styles.buttonSmallDanger]}
                onPress={() => signatureRef.current?.clear()}
              >
                <Text
                  style={[styles.buttonSmallText, styles.buttonSmallDangerText]}
                >
                  Clear
                </Text>
              </TouchableOpacity>
            </View>

            {signatureImageUrl && (
              <View style={styles.signaturePreview}>
                <Text style={styles.previewLabel}>Exported Signature:</Text>
                <Image
                  source={{ uri: signatureImageUrl }}
                  style={styles.signaturePreviewImage}
                  resizeMode="contain"
                />
              </View>
            )}
          </View>
        </SafeAreaView>
      );
    }

    // ── Placement Screen ──

    if (screen === 'placement' && pdfUrl && signatureImageUrl) {
      return (
        <View style={styles.container}>
          <StatusBar barStyle="light-content" backgroundColor="#1a1a2e" />
          <SafeAreaView style={styles.container}>
            {/* Header */}
            <View style={styles.header}>
              <TouchableOpacity
                onPress={() => {
                  setCollectedPlacements(new Map());
                  setScreen('sign');
                }}
              >
                <Text style={[styles.backButton, { color: '#e94560' }]}>
                  Cancel
                </Text>
              </TouchableOpacity>
              <Text style={styles.headerTitle}>Place Signature</Text>
              <TouchableOpacity onPress={() => placementRef.current?.confirm()}>
                <Text
                  style={[
                    styles.backButton,
                    { color: '#e94560', fontWeight: '700' },
                  ]}
                >
                  {collectedPlacements.has(placementPageIndex)
                    ? 'Update'
                    : 'Add'}
                </Text>
              </TouchableOpacity>
            </View>

            {/* Native PDF + Signature placement view */}
            <SignaturePlacement
              ref={placementRef}
              pdfUrl={pdfUrl}
              signatureImageUrl={signatureImageUrl}
              pageIndex={placementPageIndex}
              backgroundColor="#0f3460"
              onPlacementConfirmed={handlePlacementAdd}
              onPageCount={(count) => setPlacementPageCount(count)}
              style={{
                flex: 1,
                margin: 12,
                borderRadius: 8,
                overflow: 'hidden',
              }}
            />

            {/* Page navigation */}
            {placementPageCount > 1 && (
              <View
                style={{
                  flexDirection: 'row',
                  alignItems: 'center',
                  justifyContent: 'center',
                  paddingVertical: 10,
                  gap: 20,
                }}
              >
                <TouchableOpacity
                  onPress={() =>
                    setPlacementPageIndex((p) => Math.max(0, p - 1))
                  }
                  disabled={placementPageIndex === 0}
                  style={{
                    width: 36,
                    height: 36,
                    borderRadius: 18,
                    backgroundColor: '#16213e',
                    justifyContent: 'center',
                    alignItems: 'center',
                    opacity: placementPageIndex === 0 ? 0.3 : 1,
                  }}
                >
                  <Text
                    style={{
                      color: '#ffffff',
                      fontSize: 18,
                      fontWeight: '700',
                    }}
                  >
                    {'<'}
                  </Text>
                </TouchableOpacity>
                <Text style={{ color: '#aaa', fontSize: 14 }}>
                  Page {placementPageIndex + 1} of {placementPageCount}
                  {collectedPlacements.has(placementPageIndex) ? ' \u2713' : ''}
                </Text>
                <TouchableOpacity
                  onPress={() =>
                    setPlacementPageIndex((p) =>
                      Math.min(placementPageCount - 1, p + 1)
                    )
                  }
                  disabled={placementPageIndex === placementPageCount - 1}
                  style={{
                    width: 36,
                    height: 36,
                    borderRadius: 18,
                    backgroundColor: '#16213e',
                    justifyContent: 'center',
                    alignItems: 'center',
                    opacity:
                      placementPageIndex === placementPageCount - 1 ? 0.3 : 1,
                  }}
                >
                  <Text
                    style={{
                      color: '#ffffff',
                      fontSize: 18,
                      fontWeight: '700',
                    }}
                  >
                    {'>'}
                  </Text>
                </TouchableOpacity>
              </View>
            )}

            {/* Apply button */}
            <TouchableOpacity
              onPress={handleApplyAllPlacements}
              disabled={collectedPlacements.size === 0}
              style={{
                backgroundColor:
                  collectedPlacements.size > 0 ? '#e94560' : '#333',
                marginHorizontal: 24,
                paddingVertical: 14,
                borderRadius: 10,
                alignItems: 'center',
              }}
            >
              <Text style={{ color: '#fff', fontSize: 16, fontWeight: '700' }}>
                {collectedPlacements.size > 0
                  ? `Apply to ${collectedPlacements.size} page(s)`
                  : 'Tap "Add" to place signature'}
              </Text>
            </TouchableOpacity>

            <Text
              style={{
                color: '#666',
                fontSize: 12,
                textAlign: 'center',
                paddingVertical: 10,
              }}
            >
              {placementPageCount > 1
                ? 'Drag to move, pinch to resize. Tap "Add" for each page, then "Apply".'
                : 'Drag to move, pinch to resize. Tap "Add", then "Apply".'}
            </Text>
          </SafeAreaView>
        </View>
      );
    }

    // ── Sign Screen ──

    if (screen === 'sign') {
      return (
        <SafeAreaView style={styles.container}>
          <View style={styles.header}>
            <TouchableOpacity onPress={() => setScreen('home')}>
              <Text style={styles.backButton}>Back</Text>
            </TouchableOpacity>
            <Text style={styles.headerTitle}>Sign Document</Text>
            <View style={{ width: 50 }} />
          </View>

          <ScrollView contentContainerStyle={styles.scrollContent}>
            <View style={styles.infoCard}>
              <Text style={styles.infoTitle}>Ready to Sign</Text>
              <Text style={styles.infoText}>
                PDF: {pdfUrl ? 'Ready' : 'Not generated'}
              </Text>
              <Text style={styles.infoText}>
                Visual Signature: {signatureImageUrl ? 'Ready' : 'Not drawn'}
              </Text>
              <Text style={styles.infoHint}>
                Visual placement adds an image overlay. Use PAdES signing below
                for a cryptographic signature that can be verified.
              </Text>
            </View>

            {signatureImageUrl && (
              <TouchableOpacity
                style={styles.button}
                onPress={handleStartPlacement}
              >
                <Text style={styles.buttonText}>Place Signature on PDF</Text>
                <Text style={styles.buttonHint}>
                  Drag and resize on document preview
                </Text>
              </TouchableOpacity>
            )}

            <TouchableOpacity
              style={styles.button}
              onPress={() =>
                pdfUrl && requestSign(pdfUrl, activeDocumentId ?? undefined)
              }
            >
              <Text style={styles.buttonText}>Apply PAdES-B-B Signature</Text>
              <Text style={styles.buttonHint}>
                Cryptographic CMS/PKCS#7 signature
              </Text>
            </TouchableOpacity>

            {signedPdfUrl && (
              <View style={styles.successCard}>
                <Text style={styles.successTitle}>Document Signed</Text>
                <Text style={styles.fileUrl} numberOfLines={2}>
                  {signedPdfUrl}
                </Text>

                <TouchableOpacity
                  style={[styles.button, { marginTop: 12 }]}
                  onPress={handleVerifySignature}
                >
                  <Text style={styles.buttonText}>Verify Signature</Text>
                </TouchableOpacity>
              </View>
            )}
          </ScrollView>
        </SafeAreaView>
      );
    }

    // ── Verify Screen ──

    if (screen === 'verify') {
      return (
        <SafeAreaView style={styles.container}>
          <View style={styles.header}>
            <TouchableOpacity onPress={() => setScreen('home')}>
              <Text style={styles.backButton}>Back</Text>
            </TouchableOpacity>
            <Text style={styles.headerTitle}>Verification Result</Text>
            <View style={{ width: 50 }} />
          </View>

          <ScrollView contentContainerStyle={styles.scrollContent}>
            {verifyResult && (
              <>
                <View
                  style={[
                    styles.verifyCard,
                    verifyResult.signed
                      ? styles.verifyCardSigned
                      : styles.verifyCardUnsigned,
                  ]}
                >
                  <Text style={styles.verifyStatus}>
                    {verifyResult.signed ? 'SIGNED' : 'NOT SIGNED'}
                  </Text>
                  <Text style={styles.verifyCount}>
                    {verifyResult.signatures.length} signature(s) found
                  </Text>
                </View>

                {verifyResult.signatures.map((sig, index) => (
                  <View key={index} style={styles.signatureCard}>
                    <Text style={styles.signatureCardTitle}>
                      Signature #{index + 1}
                    </Text>
                    <View style={styles.signatureRow}>
                      <Text style={styles.signatureLabel}>Signer:</Text>
                      <Text style={styles.signatureValue}>
                        {sig.signerName}
                      </Text>
                    </View>
                    <View style={styles.signatureRow}>
                      <Text style={styles.signatureLabel}>Signed at:</Text>
                      <Text style={styles.signatureValue}>{sig.signedAt}</Text>
                    </View>
                    <View style={styles.signatureRow}>
                      <Text style={styles.signatureLabel}>Valid:</Text>
                      <Text
                        style={[
                          styles.signatureValue,
                          sig.valid
                            ? styles.signatureValid
                            : styles.signatureInvalid,
                        ]}
                      >
                        {sig.valid ? 'Yes' : 'No'}
                      </Text>
                    </View>
                    <View style={styles.signatureRow}>
                      <Text style={styles.signatureLabel}>Trusted:</Text>
                      <Text
                        style={[
                          styles.signatureValue,
                          sig.trusted
                            ? styles.signatureValid
                            : styles.signatureWarning,
                        ]}
                      >
                        {sig.trusted ? 'Yes' : 'Self-signed'}
                      </Text>
                    </View>
                    {sig.reason ? (
                      <View style={styles.signatureRow}>
                        <Text style={styles.signatureLabel}>Reason:</Text>
                        <Text style={styles.signatureValue}>{sig.reason}</Text>
                      </View>
                    ) : null}
                  </View>
                ))}
              </>
            )}
          </ScrollView>
        </SafeAreaView>
      );
    }

    // ── Documents Screen ──

    if (screen === 'documents') {
      return (
        <SafeAreaView style={styles.container}>
          <View style={styles.header}>
            <TouchableOpacity onPress={() => setScreen('home')}>
              <Text style={styles.backButton}>Back</Text>
            </TouchableOpacity>
            <Text style={styles.headerTitle}>Documents</Text>
            <View style={{ width: 50 }} />
          </View>

          <ScrollView contentContainerStyle={styles.scrollContent}>
            {documents.length === 0 ? (
              <View style={styles.emptyState}>
                <Text style={styles.emptyStateText}>No documents yet</Text>
                <Text style={styles.emptyStateHint}>
                  Generate a PDF to see it here
                </Text>
              </View>
            ) : (
              documents.map((doc) => (
                <View key={doc.id} style={styles.docCard}>
                  <View style={styles.docCardHeader}>
                    {doc.thumbnailUrl ? (
                      <Image
                        source={{ uri: doc.thumbnailUrl }}
                        style={styles.docThumbnail}
                        resizeMode="cover"
                      />
                    ) : (
                      <View
                        style={[
                          styles.docThumbnail,
                          styles.docThumbnailPlaceholder,
                        ]}
                      >
                        <Text style={styles.docThumbnailText}>PDF</Text>
                      </View>
                    )}
                    <View style={styles.docInfo}>
                      <Text style={styles.docName} numberOfLines={1}>
                        {doc.name}
                      </Text>
                      <Text style={styles.docDate}>
                        {doc.createdAt.toLocaleDateString()}{' '}
                        {doc.createdAt.toLocaleTimeString([], {
                          hour: '2-digit',
                          minute: '2-digit',
                        })}
                      </Text>
                      <View
                        style={[
                          styles.docBadge,
                          doc.signed
                            ? styles.docBadgeSigned
                            : styles.docBadgeUnsigned,
                        ]}
                      >
                        <Text
                          style={[
                            styles.docBadgeText,
                            doc.signed
                              ? styles.docBadgeTextSigned
                              : styles.docBadgeTextUnsigned,
                          ]}
                        >
                          {doc.signed ? 'Signed' : 'Unsigned'}
                        </Text>
                      </View>
                    </View>
                  </View>

                  <View style={styles.docActions}>
                    {!doc.signed && (
                      <TouchableOpacity
                        style={styles.docActionBtn}
                        onPress={() => handleDocumentSign(doc)}
                      >
                        <Text style={styles.docActionBtnText}>Sign</Text>
                      </TouchableOpacity>
                    )}
                    <TouchableOpacity
                      style={styles.docActionBtn}
                      onPress={() => handleDocumentVerify(doc)}
                    >
                      <Text style={styles.docActionBtnText}>Verify</Text>
                    </TouchableOpacity>
                    <TouchableOpacity
                      style={[styles.docActionBtn, styles.docActionBtnShare]}
                      onPress={() => handleDocumentShare(doc)}
                    >
                      <Text
                        style={[
                          styles.docActionBtnText,
                          styles.docActionBtnShareText,
                        ]}
                      >
                        Share
                      </Text>
                    </TouchableOpacity>
                  </View>
                </View>
              ))
            )}
          </ScrollView>
        </SafeAreaView>
      );
    }

    // ── Certificates Screen ──

    if (screen === 'certificates') {
      return (
        <SafeAreaView style={styles.container}>
          <View style={styles.header}>
            <TouchableOpacity onPress={() => setScreen('home')}>
              <Text style={styles.backButton}>Back</Text>
            </TouchableOpacity>
            <Text style={styles.headerTitle}>Certificates</Text>
            <TouchableOpacity onPress={loadCertificates}>
              <Text style={styles.actionButton}>Refresh</Text>
            </TouchableOpacity>
          </View>

          <ScrollView contentContainerStyle={styles.scrollContent}>
            <TouchableOpacity
              style={styles.buttonSecondary}
              onPress={handleGenerateCertificate}
            >
              <Text style={styles.buttonSecondaryText}>
                Generate New Certificate
              </Text>
            </TouchableOpacity>

            <TouchableOpacity
              style={styles.buttonSecondary}
              onPress={handleImportPfx}
            >
              <Text style={styles.buttonSecondaryText}>Import .pfx / .p12</Text>
            </TouchableOpacity>

            {certificates.length === 0 ? (
              <View style={styles.emptyState}>
                <Text style={styles.emptyStateText}>No certificates found</Text>
                <Text style={styles.emptyStateHint}>
                  Generate a self-signed certificate to get started
                </Text>
              </View>
            ) : (
              certificates.map((cert, index) => (
                <View key={index} style={styles.certCard}>
                  <Text style={styles.certAlias}>{cert.alias}</Text>
                  <Text style={styles.certDetail}>Subject: {cert.subject}</Text>
                  <Text style={styles.certDetail}>Issuer: {cert.issuer}</Text>
                  <Text style={styles.certDetail}>
                    Valid: {cert.validFrom} - {cert.validTo}
                  </Text>
                  <Text style={styles.certDetail}>
                    Serial: {cert.serialNumber}
                  </Text>

                  <TouchableOpacity
                    style={styles.buttonSmallDanger}
                    onPress={async () => {
                      try {
                        await Neurosign.deleteCertificate(cert.alias);
                        loadCertificates();
                      } catch (error: any) {
                        Alert.alert('Error', error.message);
                      }
                    }}
                  >
                    <Text style={styles.buttonSmallDangerText}>Delete</Text>
                  </TouchableOpacity>
                </View>
              ))
            )}
          </ScrollView>
        </SafeAreaView>
      );
    }

    return null;
  };

  return (
    <>
      {renderScreen()}
      {modals}
    </>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#F2F2F7',
    paddingTop: Platform.OS === 'android' ? StatusBar.currentHeight : 0,
  },
  scrollContent: {
    padding: 16,
    paddingBottom: 40,
  },
  loadingContainer: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  loadingText: {
    marginTop: 16,
    fontSize: 16,
    color: '#666',
  },

  // Header
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 16,
    paddingVertical: 12,
    backgroundColor: '#FFF',
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#C6C6C8',
  },
  headerTitle: {
    fontSize: 17,
    fontWeight: '600',
    color: '#000',
  },
  backButton: {
    fontSize: 17,
    color: '#007AFF',
  },
  actionButton: {
    fontSize: 17,
    color: '#007AFF',
    fontWeight: '600',
  },
  actionButtonDisabled: {
    color: '#C7C7CC',
  },

  // Title
  title: {
    fontSize: 34,
    fontWeight: '700',
    color: '#000',
    textAlign: 'center',
    marginTop: 20,
  },
  subtitle: {
    fontSize: 15,
    color: '#8E8E93',
    textAlign: 'center',
    marginBottom: 24,
  },

  // Section
  section: {
    marginBottom: 24,
  },
  sectionTitle: {
    fontSize: 20,
    fontWeight: '600',
    color: '#000',
    marginBottom: 12,
  },

  // Buttons
  button: {
    backgroundColor: '#007AFF',
    borderRadius: 12,
    padding: 16,
    marginBottom: 10,
  },
  buttonDisabled: {
    backgroundColor: '#C7C7CC',
  },
  buttonText: {
    color: '#FFF',
    fontSize: 17,
    fontWeight: '600',
  },
  buttonHint: {
    color: 'rgba(255,255,255,0.7)',
    fontSize: 13,
    marginTop: 2,
  },
  buttonSecondary: {
    backgroundColor: '#FFF',
    borderRadius: 12,
    padding: 16,
    marginBottom: 10,
    borderWidth: 1,
    borderColor: '#007AFF',
  },
  buttonSecondaryText: {
    color: '#007AFF',
    fontSize: 17,
    fontWeight: '600',
    textAlign: 'center',
  },
  buttonDanger: {
    backgroundColor: '#FF3B30',
    borderRadius: 12,
    padding: 16,
    marginTop: 8,
  },
  buttonDangerText: {
    color: '#FFF',
    fontSize: 17,
    fontWeight: '600',
    textAlign: 'center',
  },
  buttonSmall: {
    backgroundColor: '#E5E5EA',
    borderRadius: 8,
    paddingVertical: 8,
    paddingHorizontal: 16,
  },
  buttonSmallText: {
    color: '#000',
    fontSize: 15,
    fontWeight: '500',
    textAlign: 'center',
  },
  buttonSmallDanger: {
    backgroundColor: '#FFF',
    borderRadius: 8,
    paddingVertical: 8,
    paddingHorizontal: 16,
    borderWidth: 1,
    borderColor: '#FF3B30',
    marginTop: 8,
  },
  buttonSmallDangerText: {
    color: '#FF3B30',
    fontSize: 15,
    fontWeight: '500',
    textAlign: 'center',
  },

  // Status
  statusRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    paddingVertical: 8,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#E5E5EA',
  },
  statusLabel: {
    fontSize: 15,
    color: '#8E8E93',
  },
  statusValue: {
    fontSize: 15,
    color: '#000',
    fontWeight: '500',
  },

  // Images
  imageGrid: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    padding: 8,
  },
  imageCard: {
    width: (SCREEN_WIDTH - 32) / 2 - 8,
    margin: 4,
    backgroundColor: '#FFF',
    borderRadius: 8,
    overflow: 'hidden',
  },
  thumbnail: {
    width: '100%',
    height: 200,
  },
  imageLabel: {
    padding: 8,
    fontSize: 13,
    color: '#666',
    textAlign: 'center',
  },

  // Success card
  successCard: {
    backgroundColor: '#FFF',
    borderRadius: 12,
    padding: 20,
    marginBottom: 16,
    alignItems: 'center',
  },
  successIcon: {
    fontSize: 36,
    fontWeight: '800',
    color: '#007AFF',
    marginBottom: 8,
  },
  successTitle: {
    fontSize: 20,
    fontWeight: '600',
    color: '#000',
  },
  successSubtitle: {
    fontSize: 15,
    color: '#8E8E93',
    marginTop: 4,
  },
  fileUrl: {
    fontSize: 12,
    color: '#8E8E93',
    marginTop: 8,
    textAlign: 'center',
  },

  // Info card
  infoCard: {
    backgroundColor: '#FFF',
    borderRadius: 12,
    padding: 16,
    marginBottom: 16,
  },
  infoTitle: {
    fontSize: 17,
    fontWeight: '600',
    color: '#000',
    marginBottom: 8,
  },
  infoText: {
    fontSize: 15,
    color: '#666',
    marginBottom: 4,
  },
  infoHint: {
    fontSize: 13,
    color: '#8E8E93',
    marginTop: 8,
    fontStyle: 'italic',
  },

  // Signature Pad
  signaturePadContainer: {
    flex: 1,
    padding: 16,
  },
  signatureHint: {
    fontSize: 14,
    color: '#8E8E93',
    textAlign: 'center',
    marginBottom: 12,
  },
  signaturePadWrapper: {
    borderRadius: 12,
    overflow: 'hidden',
    borderWidth: 2,
    borderColor: '#E5E5EA',
    backgroundColor: '#FFF',
  },
  signaturePad: {
    width: '100%',
    height: 200,
  },
  signatureActions: {
    flexDirection: 'row',
    justifyContent: 'center',
    gap: 12,
    marginTop: 12,
  },
  signaturePreview: {
    marginTop: 20,
    alignItems: 'center',
  },
  previewLabel: {
    fontSize: 14,
    color: '#8E8E93',
    marginBottom: 8,
  },
  signaturePreviewImage: {
    width: 200,
    height: 60,
    borderWidth: 1,
    borderColor: '#E5E5EA',
    borderRadius: 8,
  },

  // Verify
  verifyCard: {
    borderRadius: 12,
    padding: 20,
    marginBottom: 16,
    alignItems: 'center',
  },
  verifyCardSigned: {
    backgroundColor: '#D4EDDA',
  },
  verifyCardUnsigned: {
    backgroundColor: '#F8D7DA',
  },
  verifyStatus: {
    fontSize: 24,
    fontWeight: '700',
  },
  verifyCount: {
    fontSize: 15,
    color: '#666',
    marginTop: 4,
  },
  signatureCard: {
    backgroundColor: '#FFF',
    borderRadius: 12,
    padding: 16,
    marginBottom: 10,
  },
  signatureCardTitle: {
    fontSize: 17,
    fontWeight: '600',
    color: '#000',
    marginBottom: 8,
  },
  signatureRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    paddingVertical: 4,
  },
  signatureLabel: {
    fontSize: 14,
    color: '#8E8E93',
  },
  signatureValue: {
    fontSize: 14,
    color: '#000',
    fontWeight: '500',
    maxWidth: '60%',
    textAlign: 'right',
  },
  signatureValid: {
    color: '#28A745',
  },
  signatureInvalid: {
    color: '#DC3545',
  },
  signatureWarning: {
    color: '#FFC107',
  },

  // Certificates
  certCard: {
    backgroundColor: '#FFF',
    borderRadius: 12,
    padding: 16,
    marginBottom: 10,
  },
  certAlias: {
    fontSize: 17,
    fontWeight: '600',
    color: '#000',
    marginBottom: 8,
  },
  certDetail: {
    fontSize: 13,
    color: '#666',
    marginBottom: 2,
  },

  // Documents
  docCard: {
    backgroundColor: '#FFF',
    borderRadius: 12,
    padding: 14,
    marginBottom: 10,
  },
  docCardHeader: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  docThumbnail: {
    width: 50,
    height: 70,
    borderRadius: 6,
    backgroundColor: '#E5E5EA',
  },
  docThumbnailPlaceholder: {
    justifyContent: 'center',
    alignItems: 'center',
  },
  docThumbnailText: {
    fontSize: 14,
    fontWeight: '700',
    color: '#8E8E93',
  },
  docInfo: {
    flex: 1,
    marginLeft: 12,
  },
  docName: {
    fontSize: 16,
    fontWeight: '600',
    color: '#000',
  },
  docDate: {
    fontSize: 13,
    color: '#8E8E93',
    marginTop: 2,
  },
  docBadge: {
    alignSelf: 'flex-start',
    borderRadius: 6,
    paddingHorizontal: 8,
    paddingVertical: 2,
    marginTop: 6,
  },
  docBadgeSigned: {
    backgroundColor: '#D4EDDA',
  },
  docBadgeUnsigned: {
    backgroundColor: '#FFF3CD',
  },
  docBadgeText: {
    fontSize: 12,
    fontWeight: '600',
  },
  docBadgeTextSigned: {
    color: '#28A745',
  },
  docBadgeTextUnsigned: {
    color: '#856404',
  },
  docActions: {
    flexDirection: 'row',
    marginTop: 12,
    gap: 8,
  },
  docActionBtn: {
    flex: 1,
    backgroundColor: '#007AFF',
    borderRadius: 8,
    paddingVertical: 8,
    alignItems: 'center',
  },
  docActionBtnText: {
    color: '#FFF',
    fontSize: 14,
    fontWeight: '600',
  },
  docActionBtnShare: {
    backgroundColor: '#FFF',
    borderWidth: 1,
    borderColor: '#007AFF',
  },
  docActionBtnShareText: {
    color: '#007AFF',
  },

  // Empty state
  emptyState: {
    alignItems: 'center',
    padding: 40,
  },
  emptyStateText: {
    fontSize: 17,
    color: '#8E8E93',
    fontWeight: '500',
  },
  emptyStateHint: {
    fontSize: 14,
    color: '#C7C7CC',
    marginTop: 4,
    textAlign: 'center',
  },

  // Footer
  footer: {
    fontSize: 12,
    color: '#C7C7CC',
    textAlign: 'center',
    marginTop: 24,
  },

  // Modals
  modalOverlay: {
    flex: 1,
    backgroundColor: 'rgba(0,0,0,0.5)',
    justifyContent: 'center',
    alignItems: 'center',
  },
  modalContent: {
    backgroundColor: '#FFF',
    borderRadius: 16,
    padding: 24,
    width: SCREEN_WIDTH - 64,
    maxHeight: '80%',
  },
  modalTitle: {
    fontSize: 20,
    fontWeight: '600',
    marginBottom: 4,
  },
  modalSubtitle: {
    fontSize: 14,
    color: '#8E8E93',
    marginBottom: 16,
  },
  modalInput: {
    borderWidth: 1,
    borderColor: '#E5E5EA',
    borderRadius: 10,
    padding: 12,
    fontSize: 16,
    marginBottom: 12,
    color: '#000',
  },
  modalActions: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    gap: 16,
    marginTop: 8,
  },
  modalCancel: {
    fontSize: 17,
    color: '#8E8E93',
  },
  modalConfirm: {
    fontSize: 17,
    color: '#007AFF',
    fontWeight: '600',
  },

  // Certificate picker
  certPickerItem: {
    padding: 14,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: '#E5E5EA',
  },
  certPickerAlias: {
    fontSize: 16,
    fontWeight: '600',
    color: '#000',
  },
  certPickerDetail: {
    fontSize: 13,
    color: '#8E8E93',
    marginTop: 2,
  },
});
