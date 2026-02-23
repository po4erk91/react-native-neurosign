import type { HostComponent, ViewProps } from 'react-native';
import type {
  DirectEventHandler,
  Double,
  Int32,
} from 'react-native/Libraries/Types/CodegenTypes';
import codegenNativeCommands from 'react-native/Libraries/Utilities/codegenNativeCommands';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';

export interface NativeSignaturePlacementViewProps extends ViewProps {
  pdfUrl: string;
  signatureImageUrl: string;
  pageIndex: Int32;
  defaultPositionX?: Double;
  defaultPositionY?: Double;
  placeholderBackgroundColor?: string;
  sigBorderColor?: string;
  sigBorderWidth?: Double;
  sigBorderPadding?: Double;
  sigCornerSize?: Double;
  sigCornerWidth?: Double;
  sigBorderRadius?: Double;
  onPlacementConfirmed?: DirectEventHandler<
    Readonly<{
      pageIndex: Int32;
      x: Double;
      y: Double;
      width: Double;
      height: Double;
    }>
  >;
  onPageCount?: DirectEventHandler<Readonly<{ count: Int32 }>>;
}

export type SignaturePlacementViewType =
  HostComponent<NativeSignaturePlacementViewProps>;

interface NativeCommands {
  confirm: (viewRef: React.ElementRef<SignaturePlacementViewType>) => void;
  reset: (viewRef: React.ElementRef<SignaturePlacementViewType>) => void;
}

export const Commands: NativeCommands = codegenNativeCommands<NativeCommands>({
  supportedCommands: ['confirm', 'reset'],
});

export default codegenNativeComponent<NativeSignaturePlacementViewProps>(
  'NeurosignSignaturePlacementView'
) as SignaturePlacementViewType;
