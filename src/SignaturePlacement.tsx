import { forwardRef, useCallback, useImperativeHandle, useRef } from 'react';
import type { StyleProp, ViewStyle } from 'react-native';
import NativeSignaturePlacementView, {
  Commands,
  type SignaturePlacementViewType,
} from './NativeSignaturePlacementView';

export interface SignaturePlacementRef {
  confirm: () => void;
  reset: () => void;
}

/** Styling options for the signature overlay (border, corners). */
export interface SignatureStyle {
  /** Color of the dashed border and corner handles (hex, e.g. "#E94560"). Default: "#E94560". */
  borderColor?: string;
  /** Stroke width of the dashed border in dp/pt. Default: 2. */
  borderWidth?: number;
  /** Padding between signature image and border in dp/pt. Default: 0. */
  borderPadding?: number;
  /** Length of L-shaped corner handles in dp/pt. Default: 14. */
  cornerSize?: number;
  /** Stroke width of corner handles in dp/pt. Default: 3. */
  cornerWidth?: number;
  /** Border radius of the dashed border in dp/pt. Default: 0. */
  borderRadius?: number;
}

export interface SignaturePlacementProps {
  pdfUrl: string;
  signatureImageUrl: string;
  pageIndex?: number;
  /** Default X position (normalized 0-1). Omit or -1 for center. */
  defaultPositionX?: number;
  /** Default Y position (normalized 0-1). Omit or -1 for center. */
  defaultPositionY?: number;
  /** Background color of the view behind the PDF (hex, e.g. "#0f3460"). */
  backgroundColor?: string;
  /** Styling for the signature overlay (border, corners). */
  signature?: SignatureStyle;
  onPlacementConfirmed?: (placement: {
    pageIndex: number;
    x: number;
    y: number;
    width: number;
    height: number;
  }) => void;
  onPageCount?: (count: number) => void;
  style?: StyleProp<ViewStyle>;
}

export const SignaturePlacement = forwardRef<
  SignaturePlacementRef,
  SignaturePlacementProps
>(
  (
    {
      pdfUrl,
      signatureImageUrl,
      pageIndex = 0,
      defaultPositionX,
      defaultPositionY,
      backgroundColor,
      signature,
      onPlacementConfirmed,
      onPageCount,
      style,
    },
    ref
  ) => {
    const nativeRef =
      useRef<React.ElementRef<SignaturePlacementViewType>>(null);

    useImperativeHandle(ref, () => ({
      confirm: () => {
        if (nativeRef.current) {
          Commands.confirm(nativeRef.current);
        }
      },
      reset: () => {
        if (nativeRef.current) {
          Commands.reset(nativeRef.current);
        }
      },
    }));

    const handlePlacementConfirmed = useCallback(
      (event: {
        nativeEvent: {
          pageIndex: number;
          x: number;
          y: number;
          width: number;
          height: number;
        };
      }) => {
        onPlacementConfirmed?.(event.nativeEvent);
      },
      [onPlacementConfirmed]
    );

    const handlePageCount = useCallback(
      (event: { nativeEvent: { count: number } }) => {
        onPageCount?.(event.nativeEvent.count);
      },
      [onPageCount]
    );

    return (
      <NativeSignaturePlacementView
        ref={nativeRef}
        pdfUrl={pdfUrl}
        signatureImageUrl={signatureImageUrl}
        pageIndex={pageIndex}
        defaultPositionX={defaultPositionX}
        defaultPositionY={defaultPositionY}
        placeholderBackgroundColor={backgroundColor}
        sigBorderColor={signature?.borderColor}
        sigBorderWidth={signature?.borderWidth}
        sigBorderPadding={signature?.borderPadding}
        sigCornerSize={signature?.cornerSize}
        sigCornerWidth={signature?.cornerWidth}
        sigBorderRadius={signature?.borderRadius}
        onPlacementConfirmed={handlePlacementConfirmed}
        onPageCount={handlePageCount}
        style={style}
      />
    );
  }
);

SignaturePlacement.displayName = 'SignaturePlacement';
