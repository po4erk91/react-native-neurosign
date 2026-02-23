import type { HostComponent, ViewProps } from 'react-native';
import type {
  DirectEventHandler,
  Float,
  Int32,
} from 'react-native/Libraries/Types/CodegenTypes';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';
import codegenNativeCommands from 'react-native/Libraries/Utilities/codegenNativeCommands';

export interface NativeSignaturePadViewProps extends ViewProps {
  strokeColor?: string;
  strokeWidth?: Float;
  backgroundColor?: string;
  minStrokeWidth?: Float;
  maxStrokeWidth?: Float;
  onDrawingChanged?: DirectEventHandler<
    Readonly<{ hasDrawing: boolean }>
  >;
  onSignatureExported?: DirectEventHandler<
    Readonly<{ imageUrl: string }>
  >;
}

export type SignaturePadViewType = HostComponent<NativeSignaturePadViewProps>;

interface NativeCommands {
  clear: (viewRef: React.ElementRef<SignaturePadViewType>) => void;
  undo: (viewRef: React.ElementRef<SignaturePadViewType>) => void;
  redo: (viewRef: React.ElementRef<SignaturePadViewType>) => void;
  exportSignature: (
    viewRef: React.ElementRef<SignaturePadViewType>,
    format: string,
    quality: Int32
  ) => void;
}

export const Commands: NativeCommands = codegenNativeCommands<NativeCommands>({
  supportedCommands: ['clear', 'undo', 'redo', 'exportSignature'],
});

export default codegenNativeComponent<NativeSignaturePadViewProps>(
  'SignaturePadView'
) as SignaturePadViewType;
