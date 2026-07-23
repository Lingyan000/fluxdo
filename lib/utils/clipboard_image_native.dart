/// 剪贴板位图的原生兜底读取(仅 Windows 有实现)。
///
/// **为什么需要它**:Windows 剪贴板历史(Win+V)粘贴图片时,系统放的 OLE
/// data object 只在 OLE 层声明标记类格式(`ClipboardHistoryItemId` /
/// `ExcludeClipboardContentFromMonitorProcessing` / `DropDescription`),
/// 位图挂在**原始 Win32 剪贴板**上。super_clipboard 走 `IDataObject`
/// 枚举,于是一张位图都看不到 —— 表现为「Win+V 粘贴图片没反应」,而
/// Chrome 这类直接读原始剪贴板的应用正常。
///
/// 探针实测(Win+V 选历史图片):
/// ```
/// Win32 EnumClipboardFormats: CF_BITMAP / CF_DIB / CF_DIBV5  handle 均有效
/// super_clipboard platformFormats: 只有两个标记格式
/// ```
/// 同一张图直接 Ctrl+C 复制则两边都正常 —— 只有走剪贴板历史这条路会这样。
library;

export 'clipboard_image_native_stub.dart'
    if (dart.library.io) 'clipboard_image_native_io.dart';
