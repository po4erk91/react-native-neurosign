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

@interface SignaturePadViewManager : RCTViewManager
@end

@implementation SignaturePadViewManager

RCT_EXPORT_MODULE(SignaturePadView)

- (UIView *)view {
    return [[SignaturePadView alloc] init];
}

RCT_EXPORT_VIEW_PROPERTY(strokeColor, UIColor)
RCT_EXPORT_VIEW_PROPERTY(strokeWidth, CGFloat)
RCT_EXPORT_VIEW_PROPERTY(minStrokeWidth, CGFloat)
RCT_EXPORT_VIEW_PROPERTY(maxStrokeWidth, CGFloat)
RCT_EXPORT_VIEW_PROPERTY(onDrawingChanged, RCTDirectEventBlock)
RCT_EXPORT_VIEW_PROPERTY(onSignatureExported, RCTDirectEventBlock)

RCT_EXPORT_METHOD(clear:(nonnull NSNumber *)reactTag) {
    [self.bridge.uiManager addUIBlock:^(RCTUIManager *uiManager, NSDictionary<NSNumber *, UIView *> *viewRegistry) {
        SignaturePadView *view = (SignaturePadView *)viewRegistry[reactTag];
        if ([view isKindOfClass:[SignaturePadView class]]) {
            [view clear];
        }
    }];
}

RCT_EXPORT_METHOD(undo:(nonnull NSNumber *)reactTag) {
    [self.bridge.uiManager addUIBlock:^(RCTUIManager *uiManager, NSDictionary<NSNumber *, UIView *> *viewRegistry) {
        SignaturePadView *view = (SignaturePadView *)viewRegistry[reactTag];
        if ([view isKindOfClass:[SignaturePadView class]]) {
            [view undo];
        }
    }];
}

RCT_EXPORT_METHOD(redo:(nonnull NSNumber *)reactTag) {
    [self.bridge.uiManager addUIBlock:^(RCTUIManager *uiManager, NSDictionary<NSNumber *, UIView *> *viewRegistry) {
        SignaturePadView *view = (SignaturePadView *)viewRegistry[reactTag];
        if ([view isKindOfClass:[SignaturePadView class]]) {
            [view redo];
        }
    }];
}

RCT_EXPORT_METHOD(exportSignature:(nonnull NSNumber *)reactTag
                           format:(NSString *)format
                          quality:(double)quality) {
    [self.bridge.uiManager addUIBlock:^(RCTUIManager *uiManager, NSDictionary<NSNumber *, UIView *> *viewRegistry) {
        SignaturePadView *view = (SignaturePadView *)viewRegistry[reactTag];
        if ([view isKindOfClass:[SignaturePadView class]]) {
            [view exportSignatureWithFormat:format quality:(int)quality];
        }
    }];
}

@end
