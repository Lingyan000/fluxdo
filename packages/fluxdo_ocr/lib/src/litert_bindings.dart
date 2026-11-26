part of '../fluxdo_ocr.dart';

// LiteRT 2.4.0 保留的 Interpreter C API。动态输出由运行库分配，避免外部缓冲区尺寸滞后。

final class _XnnOptions extends Struct {
  @Int32()
  external int numThreads;
  @Uint32()
  external int runtimeFlags;
  @Uint32()
  external int flags;
  external Pointer<Void> weightsCache;
  @Bool()
  external bool handleVariableOps;
  external Pointer<Utf8> weightCacheFilePath;
  @Int32()
  external int weightCacheFileDescriptor;
  external Pointer<Void> weightCacheProvider;
  @Bool()
  external bool weightCacheLockMemory;
}

@Native<_XnnOptions Function()>(
  symbol: 'TfLiteXNNPackDelegateOptionsDefault',
  assetId: _runtime,
)
external _XnnOptions _xnnOptionsDefault();

@Native<Pointer<Void> Function(Pointer<_XnnOptions>)>(
  symbol: 'TfLiteXNNPackDelegateCreate',
  assetId: _runtime,
)
external Pointer<Void> _xnnCreate(Pointer<_XnnOptions> options);

@Native<Void Function(Pointer<Void>)>(
  symbol: 'TfLiteXNNPackDelegateDelete',
  assetId: _runtime,
)
external void _xnnDelete(Pointer<Void> delegate);

@Native<Void Function(Pointer<Void>, Pointer<Void>)>(
  symbol: 'TfLiteInterpreterOptionsAddDelegate',
  assetId: _runtime,
)
external void _optionsAddDelegate(
  Pointer<Void> options,
  Pointer<Void> delegate,
);

@Native<Pointer<Void> Function(Pointer<Uint8>, Size)>(
  symbol: 'TfLiteModelCreate',
  assetId: _runtime,
)
external Pointer<Void> _modelCreate(Pointer<Uint8> data, int length);

@Native<Void Function(Pointer<Void>)>(
  symbol: 'TfLiteModelDelete',
  assetId: _runtime,
)
external void _modelDelete(Pointer<Void> model);

@Native<Pointer<Void> Function()>(
  symbol: 'TfLiteInterpreterOptionsCreate',
  assetId: _runtime,
)
external Pointer<Void> _optionsCreate();

@Native<Void Function(Pointer<Void>)>(
  symbol: 'TfLiteInterpreterOptionsDelete',
  assetId: _runtime,
)
external void _optionsDelete(Pointer<Void> options);

@Native<Void Function(Pointer<Void>, Int32)>(
  symbol: 'TfLiteInterpreterOptionsSetNumThreads',
  assetId: _runtime,
)
external void _optionsThreads(Pointer<Void> options, int threads);

@Native<Pointer<Void> Function(Pointer<Void>, Pointer<Void>)>(
  symbol: 'TfLiteInterpreterCreate',
  assetId: _runtime,
)
external Pointer<Void> _interpreterCreate(
  Pointer<Void> model,
  Pointer<Void> options,
);

@Native<Void Function(Pointer<Void>)>(
  symbol: 'TfLiteInterpreterDelete',
  assetId: _runtime,
)
external void _interpreterDelete(Pointer<Void> interpreter);

@Native<Int32 Function(Pointer<Void>)>(
  symbol: 'TfLiteInterpreterGetInputTensorCount',
  assetId: _runtime,
)
external int _inputCount(Pointer<Void> interpreter);

@Native<Int32 Function(Pointer<Void>)>(
  symbol: 'TfLiteInterpreterGetOutputTensorCount',
  assetId: _runtime,
)
external int _outputCount(Pointer<Void> interpreter);

@Native<Pointer<Void> Function(Pointer<Void>, Int32)>(
  symbol: 'TfLiteInterpreterGetInputTensor',
  assetId: _runtime,
)
external Pointer<Void> _inputTensor(Pointer<Void> interpreter, int index);

@Native<Pointer<Void> Function(Pointer<Void>, Int32)>(
  symbol: 'TfLiteInterpreterGetOutputTensor',
  assetId: _runtime,
)
external Pointer<Void> _outputTensor(Pointer<Void> interpreter, int index);

@Native<Int32 Function(Pointer<Void>)>(
  symbol: 'TfLiteTensorType',
  assetId: _runtime,
)
external int _tensorType(Pointer<Void> tensor);

@Native<Int32 Function(Pointer<Void>)>(
  symbol: 'TfLiteTensorNumDims',
  assetId: _runtime,
)
external int _tensorRank(Pointer<Void> tensor);

@Native<Int32 Function(Pointer<Void>, Int32)>(
  symbol: 'TfLiteTensorDim',
  assetId: _runtime,
)
external int _tensorDim(Pointer<Void> tensor, int index);

@Native<Size Function(Pointer<Void>)>(
  symbol: 'TfLiteTensorByteSize',
  assetId: _runtime,
)
external int _tensorBytes(Pointer<Void> tensor);

@Native<Pointer<Float> Function(Pointer<Void>)>(
  symbol: 'TfLiteTensorData',
  assetId: _runtime,
)
external Pointer<Float> _tensorData(Pointer<Void> tensor);

@Native<Int32 Function(Pointer<Void>, Int32, Pointer<Int32>, Int32)>(
  symbol: 'TfLiteInterpreterResizeInputTensor',
  assetId: _runtime,
)
external int _resizeInput(
  Pointer<Void> interpreter,
  int index,
  Pointer<Int32> dimensions,
  int rank,
);

@Native<Int32 Function(Pointer<Void>)>(
  symbol: 'TfLiteInterpreterAllocateTensors',
  assetId: _runtime,
)
external int _allocateTensors(Pointer<Void> interpreter);

@Native<Int32 Function(Pointer<Void>)>(
  symbol: 'TfLiteInterpreterInvoke',
  assetId: _runtime,
)
external int _invoke(Pointer<Void> interpreter);
