#import <React/RCTViewManager.h>
#import <React/RCTUIManager.h>

// Import Swift-generated header
#if __has_include("react_native_neurosign/react_native_neurosign-Swift.h")
#import "react_native_neurosign/react_native_neurosign-Swift.h"
#elif __has_include("react-native-neurosign/react-native-neurosign-Swift.h")
#import "react-native-neurosign/react-native-neurosign-Swift.h"
#else
#import "Neurosign-Swift.h"
#endif

@interface SignaturePlacementViewManager : RCTViewManager
@end

@implementation SignaturePlacementViewManager

RCT_EXPORT_MODULE(NeurosignSignaturePlacementView)

- (UIView *)view {
    return [[SignaturePlacementView alloc] init];
}

RCT_EXPORT_VIEW_PROPERTY(pdfUrl, NSString)
RCT_EXPORT_VIEW_PROPERTY(signatureImageUrl, NSString)
RCT_EXPORT_VIEW_PROPERTY(pageIndex, NSInteger)
RCT_EXPORT_VIEW_PROPERTY(defaultPositionX, CGFloat)
RCT_EXPORT_VIEW_PROPERTY(defaultPositionY, CGFloat)
RCT_EXPORT_VIEW_PROPERTY(placeholderBackgroundColor, NSString)
RCT_EXPORT_VIEW_PROPERTY(sigBorderColor, NSString)
RCT_EXPORT_VIEW_PROPERTY(sigBorderWidth, CGFloat)
RCT_EXPORT_VIEW_PROPERTY(sigBorderPadding, CGFloat)
RCT_EXPORT_VIEW_PROPERTY(sigCornerSize, CGFloat)
RCT_EXPORT_VIEW_PROPERTY(sigCornerWidth, CGFloat)
RCT_EXPORT_VIEW_PROPERTY(sigBorderRadius, CGFloat)
RCT_EXPORT_VIEW_PROPERTY(onPlacementConfirmed, RCTDirectEventBlock)
RCT_EXPORT_VIEW_PROPERTY(onPageCount, RCTDirectEventBlock)

RCT_EXPORT_METHOD(confirm:(nonnull NSNumber *)reactTag) {
    [self.bridge.uiManager addUIBlock:^(RCTUIManager *uiManager, NSDictionary<NSNumber *, UIView *> *viewRegistry) {
        SignaturePlacementView *view = (SignaturePlacementView *)viewRegistry[reactTag];
        if ([view isKindOfClass:[SignaturePlacementView class]]) {
            [view confirm];
        }
    }];
}

RCT_EXPORT_METHOD(reset:(nonnull NSNumber *)reactTag) {
    [self.bridge.uiManager addUIBlock:^(RCTUIManager *uiManager, NSDictionary<NSNumber *, UIView *> *viewRegistry) {
        SignaturePlacementView *view = (SignaturePlacementView *)viewRegistry[reactTag];
        if ([view isKindOfClass:[SignaturePlacementView class]]) {
            [view reset];
        }
    }];
}

@end
