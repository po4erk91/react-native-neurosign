#import "Neurosign.h"

// Import Swift-generated header
#if __has_include("react_native_neurosign/react_native_neurosign-Swift.h")
#import "react_native_neurosign/react_native_neurosign-Swift.h"
#elif __has_include("react-native-neurosign/react-native-neurosign-Swift.h")
#import "react-native-neurosign/react-native-neurosign-Swift.h"
#else
#import "Neurosign-Swift.h"
#endif

@implementation Neurosign {
    NeurosignImpl *_impl;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _impl = [[NeurosignImpl alloc] init];
    }
    return self;
}

+ (NSString *)moduleName {
    return @"Neurosign";
}

// MARK: - generatePdf

- (void)generatePdf:(JS::NativeNeurosign::SpecGeneratePdfOptions &)options
            resolve:(RCTPromiseResolveBlock)resolve
             reject:(RCTPromiseRejectBlock)reject {
    NSArray<NSString *> *imageUrls = [self convertStringArray:options.imageUrls()];
    NSString *fileName = options.fileName() ?: @"document";
    NSString *pageSize = options.pageSize() ?: @"A4";
    double pageMargin = options.pageMargin().has_value() ? options.pageMargin().value() : 20;
    double quality = options.quality().has_value() ? options.quality().value() : 90;

    [_impl generatePdfWithImageUrls:imageUrls
                           fileName:fileName
                           pageSize:pageSize
                         pageMargin:pageMargin
                            quality:quality
                           resolver:^(NSDictionary *result) {
        resolve(result);
    } rejecter:^(NSString *code, NSString *message, NSError *error) {
        reject(code, message, error);
    }];
}

// MARK: - addSignatureImage

- (void)addSignatureImage:(JS::NativeNeurosign::SpecAddSignatureImageOptions &)options
                  resolve:(RCTPromiseResolveBlock)resolve
                   reject:(RCTPromiseRejectBlock)reject {
    NSString *pdfUrl = options.pdfUrl();
    NSString *signatureImageUrl = options.signatureImageUrl();
    double pageIndex = options.pageIndex();
    double x = options.x();
    double y = options.y();
    double width = options.width();
    double height = options.height();

    [_impl addSignatureImageWithPdfUrl:pdfUrl
                     signatureImageUrl:signatureImageUrl
                             pageIndex:(NSInteger)pageIndex
                                     x:x
                                     y:y
                                 width:width
                                height:height
                              resolver:^(NSDictionary *result) {
        resolve(result);
    } rejecter:^(NSString *code, NSString *message, NSError *error) {
        reject(code, message, error);
    }];
}

// MARK: - renderPdfPage

- (void)renderPdfPage:(JS::NativeNeurosign::SpecRenderPdfPageOptions &)options
              resolve:(RCTPromiseResolveBlock)resolve
               reject:(RCTPromiseRejectBlock)reject {
    NSString *pdfUrl = options.pdfUrl();
    double pageIndex = options.pageIndex();
    double width = options.width();
    double height = options.height();

    [_impl renderPdfPageWithPdfUrl:pdfUrl
                         pageIndex:(NSInteger)pageIndex
                             width:width
                            height:height
                          resolver:^(NSDictionary *result) {
        resolve(result);
    } rejecter:^(NSString *code, NSString *message, NSError *error) {
        reject(code, message, error);
    }];
}

// MARK: - signPdf

- (void)signPdf:(JS::NativeNeurosign::SpecSignPdfOptions &)options
        resolve:(RCTPromiseResolveBlock)resolve
         reject:(RCTPromiseRejectBlock)reject {
    NSString *pdfUrl = options.pdfUrl();
    NSString *certificateType = options.certificateType();
    NSString *certificatePath = options.certificatePath();
    NSString *certificatePassword = options.certificatePassword();
    NSString *keychainAlias = options.keychainAlias();
    NSString *reason = options.reason() ?: @"";
    NSString *location = options.location() ?: @"";
    NSString *contactInfo = options.contactInfo() ?: @"";

    [_impl signPdfWithPdfUrl:pdfUrl
             certificateType:certificateType
             certificatePath:certificatePath
         certificatePassword:certificatePassword
               keychainAlias:keychainAlias
                      reason:reason
                    location:location
                 contactInfo:contactInfo
                    resolver:^(NSDictionary *result) {
        resolve(result);
    } rejecter:^(NSString *code, NSString *message, NSError *error) {
        reject(code, message, error);
    }];
}

// MARK: - verifySignature

- (void)verifySignature:(NSString *)pdfUrl
                resolve:(RCTPromiseResolveBlock)resolve
                 reject:(RCTPromiseRejectBlock)reject {
    [_impl verifySignatureWithPdfUrl:pdfUrl
                            resolver:^(NSDictionary *result) {
        resolve(result);
    } rejecter:^(NSString *code, NSString *message, NSError *error) {
        reject(code, message, error);
    }];
}

// MARK: - Certificate Management

- (void)importCertificate:(JS::NativeNeurosign::SpecImportCertificateOptions &)options
                  resolve:(RCTPromiseResolveBlock)resolve
                   reject:(RCTPromiseRejectBlock)reject {
    NSString *certificatePath = options.certificatePath();
    NSString *password = options.password();
    NSString *alias = options.alias();

    [_impl importCertificateWithCertificatePath:certificatePath
                                       password:password
                                          alias:alias
                                       resolver:^(NSDictionary *result) {
        resolve(result);
    } rejecter:^(NSString *code, NSString *message, NSError *error) {
        reject(code, message, error);
    }];
}

- (void)generateSelfSignedCertificate:(JS::NativeNeurosign::SpecGenerateSelfSignedCertificateOptions &)options
                              resolve:(RCTPromiseResolveBlock)resolve
                               reject:(RCTPromiseRejectBlock)reject {
    NSString *commonName = options.commonName();
    NSString *organization = options.organization() ?: @"";
    NSString *country = options.country() ?: @"";
    NSInteger validityDays = options.validityDays().has_value() ? options.validityDays().value() : 365;
    NSString *alias = options.alias();
    NSString *keyAlgorithm = options.keyAlgorithm() ?: @"RSA";

    [_impl generateSelfSignedCertificateWithCommonName:commonName
                                          organization:organization
                                               country:country
                                          validityDays:(int)validityDays
                                                 alias:alias
                                          keyAlgorithm:keyAlgorithm
                                              resolver:^(NSDictionary *result) {
        resolve(result);
    } rejecter:^(NSString *code, NSString *message, NSError *error) {
        reject(code, message, error);
    }];
}

- (void)listCertificates:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject {
    [_impl listCertificatesWithResolver:^(NSArray *result) {
        resolve(result);
    } rejecter:^(NSString *code, NSString *message, NSError *error) {
        reject(code, message, error);
    }];
}

- (void)deleteCertificate:(NSString *)alias
                  resolve:(RCTPromiseResolveBlock)resolve
                   reject:(RCTPromiseRejectBlock)reject {
    [_impl deleteCertificateWithAlias:alias
                             resolver:^(NSNumber *result) {
        resolve(result);
    } rejecter:^(NSString *code, NSString *message, NSError *error) {
        reject(code, message, error);
    }];
}

// MARK: - External Signing

- (void)prepareForExternalSigning:(JS::NativeNeurosign::SpecPrepareForExternalSigningOptions &)options
                          resolve:(RCTPromiseResolveBlock)resolve
                           reject:(RCTPromiseRejectBlock)reject {
    NSString *pdfUrl = options.pdfUrl();
    NSString *reason = options.reason() ?: @"";
    NSString *location = options.location() ?: @"";
    NSString *contactInfo = options.contactInfo() ?: @"";

    [_impl prepareForExternalSigningWithPdfUrl:pdfUrl
                                        reason:reason
                                      location:location
                                   contactInfo:contactInfo
                                      resolver:^(NSDictionary *result) {
        resolve(result);
    } rejecter:^(NSString *code, NSString *message, NSError *error) {
        reject(code, message, error);
    }];
}

- (void)completeExternalSigning:(JS::NativeNeurosign::SpecCompleteExternalSigningOptions &)options
                        resolve:(RCTPromiseResolveBlock)resolve
                         reject:(RCTPromiseRejectBlock)reject {
    NSString *preparedPdfUrl = options.preparedPdfUrl();
    NSString *signature = options.signature();

    [_impl completeExternalSigningWithPreparedPdfUrl:preparedPdfUrl
                                           signature:signature
                                            resolver:^(NSDictionary *result) {
        resolve(result);
    } rejecter:^(NSString *code, NSString *message, NSError *error) {
        reject(code, message, error);
    }];
}

// MARK: - exportSignature

- (void)exportSignature:(double)viewTag
                 format:(NSString *)format
                quality:(double)quality
                resolve:(RCTPromiseResolveBlock)resolve
                 reject:(RCTPromiseRejectBlock)reject {
    // Delegated to SignaturePadView via commands; this is a fallback
    reject(@"SIGNATURE_FAILED", @"Use SignaturePad component commands to export", nil);
}

// MARK: - cleanupTempFiles

- (void)cleanupTempFiles:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject {
    [_impl cleanupTempFilesWithResolver:^(NSNumber *result) {
        resolve(result);
    } rejecter:^(NSString *code, NSString *message, NSError *error) {
        reject(code, message, error);
    }];
}

// MARK: - Helpers

- (NSArray<NSString *> *)convertStringArray:(id)input {
    if ([input isKindOfClass:[NSArray class]]) {
        return (NSArray<NSString *> *)input;
    }
    return @[];
}

// MARK: - TurboModule

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params {
    return std::make_shared<facebook::react::NativeNeurosignSpecJSI>(params);
}

@end
