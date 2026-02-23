import {
  forwardRef,
  useCallback,
  useImperativeHandle,
  useRef,
} from 'react';
import type { StyleProp, ViewStyle } from 'react-native';
import NativeSignaturePadView, {
  Commands,
  type SignaturePadViewType,
} from './NativeSignaturePadView';

export interface SignaturePadRef {
  clear: () => void;
  undo: () => void;
  redo: () => void;
  exportSignature: (format?: 'png' | 'svg', quality?: number) => void;
}

export interface SignaturePadProps {
  strokeColor?: string;
  strokeWidth?: number;
  backgroundColor?: string;
  minStrokeWidth?: number;
  maxStrokeWidth?: number;
  onDrawingChanged?: (hasDrawing: boolean) => void;
  onSignatureExported?: (imageUrl: string) => void;
  style?: StyleProp<ViewStyle>;
}

export const SignaturePad = forwardRef<SignaturePadRef, SignaturePadProps>(
  (
    {
      strokeColor = '#000000',
      strokeWidth = 2,
      backgroundColor = '#FFFFFF',
      minStrokeWidth = 1,
      maxStrokeWidth = 5,
      onDrawingChanged,
      onSignatureExported,
      style,
    },
    ref
  ) => {
    const nativeRef = useRef<React.ElementRef<SignaturePadViewType>>(null);

    useImperativeHandle(ref, () => ({
      clear: () => {
        if (nativeRef.current) {
          Commands.clear(nativeRef.current);
        }
      },
      undo: () => {
        if (nativeRef.current) {
          Commands.undo(nativeRef.current);
        }
      },
      redo: () => {
        if (nativeRef.current) {
          Commands.redo(nativeRef.current);
        }
      },
      exportSignature: (format: 'png' | 'svg' = 'png', quality = 90) => {
        if (nativeRef.current) {
          Commands.exportSignature(nativeRef.current, format, quality);
        }
      },
    }));

    const handleDrawingChanged = useCallback(
      (event: { nativeEvent: { hasDrawing: boolean } }) => {
        onDrawingChanged?.(event.nativeEvent.hasDrawing);
      },
      [onDrawingChanged]
    );

    const handleSignatureExported = useCallback(
      (event: { nativeEvent: { imageUrl: string } }) => {
        onSignatureExported?.(event.nativeEvent.imageUrl);
      },
      [onSignatureExported]
    );

    return (
      <NativeSignaturePadView
        ref={nativeRef}
        strokeColor={strokeColor}
        strokeWidth={strokeWidth}
        backgroundColor={backgroundColor}
        minStrokeWidth={minStrokeWidth}
        maxStrokeWidth={maxStrokeWidth}
        onDrawingChanged={handleDrawingChanged}
        onSignatureExported={handleSignatureExported}
        style={style}
      />
    );
  }
);

SignaturePad.displayName = 'SignaturePad';
