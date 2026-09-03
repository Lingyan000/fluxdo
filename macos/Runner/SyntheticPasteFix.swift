import Cocoa
import FlutterMacOS

/// CGEvent 注入式 Cmd+V 的粘贴补丁 —— 绕过 Flutter macOS 的一个上游缺陷。
///
/// ## 症状
///
/// 语音输入法(Wispr Flow / SuperWhisper / 讯飞等)、剪贴板管理器(Raycast /
/// Alfred / Paste)、文本扩展(TextExpander 等)在 Mac 上的"粘贴"都是同一套做法:
/// 把文本写进系统剪贴板,再用 `CGEventPost` 注入一次 Cmd+V。这类注入在**所有**
/// Flutter macOS 应用里都会静默失灵 —— 输入框毫无反应(偶尔冒出一个裸 `v`),
/// 而同样的注入在 TextEdit/Safari/Notes 乃至 Electron 应用里都正常。
///
/// 上游 issue: https://github.com/flutter/flutter/issues/184571
/// (2026-04 提出, 官方标 P2 + workaround available, 至今未修。官方修复后
/// 本文件可整体删除 —— 判据见下方"退场条件"。)
///
/// ## 根因(上游 issue 中经真机日志核对过的结论)
///
/// Command 修饰位**并没有丢**:NSEvent 与底层 CGEvent 的 flags 里 Command 都在。
/// 真正的问题是 Flutter 的 `HardwareKeyboard` **只认 `flagsChanged` 事件流来
/// 维护修饰键状态,不读 keyDown 自带的 flags 字段**。而注入工具往往只投一个
/// "带 Command 标志的 V keyDown",不投独立的 flagsChanged —— 于是框架侧认定
/// "Cmd 没按下",把事件当成裸 `v`,编辑器的 `Cmd+V = 粘贴` 判据自然不成立。
///
/// 更阴的是后半段:事件继续落到 AppKit 的 key-binding 路径,对无障碍隐藏文本框
/// (`FlutterTextField`)执行了 `paste:`,文本进了那个影子控件的存储,**从未到达
/// Flutter 框架**。注入工具的 AX 回读因此能"读到"文本、自认为粘贴成功,用户屏幕上
/// 却什么都没有 —— 两边都以为成功了。
///
/// ## 本补丁的做法
///
/// 用 local monitor 跟踪"事件流里是否出现过真正的 flagsChanged Command"。
/// **只有当一次 Cmd+V 的 Command 仅存在于事件 flags、且前面没有 flagsChanged 时**,
/// 才判定为"框架会丢掉的那种合成事件":此时读剪贴板,直接调用
/// `NSTextInputClient.insertText(_:replacementRange:)` 把文本交给 Flutter
/// (系统听写走的同一条 IME 通道,自研编辑器的 EditorImeClient 完整处理这条路),
/// 然后吞掉事件,避免框架再收到那个裸 `v`。
///
/// 判据的精度决定了这个补丁的安全性:
/// - **物理键盘** Cmd+V 一定先发 flagsChanged → 判据不成立 → 完全走原有框架路径,
///   既有的富文本/Markdown 粘贴逻辑(richPasteImporter → markdownImporter)不受影响,
///   也不会双重粘贴;
/// - **规矩的合成注入**(投了完整 Cmd 按下/抬起)同样先发 flagsChanged → 走原路径;
/// - 只有会失败的那一种形态被接管。
///
/// 代价:被接管的那次粘贴走纯文本插入,不经过富格式转换。语音输入场景本就是纯文本,
/// 够用;真要富文本的用户会用物理键盘,走的是原路径。
///
/// ## 验证陷阱(上游踩过,别重蹈)
///
/// 1. **不能用 `performKeyEquivalent` 拦截**:这类合成事件根本不触发它
///    (issue 作者最初的 workaround 就栽在这,后来发帖更正)。唯一可靠的拦截点
///    就是 `addLocalMonitorForEvents`。
/// 2. **不能用 `CGEventSource.keyState` 判断"Cmd 是否真按下"来区分合成/物理**:
///    注入事件自身会更新事件源的修饰键状态,判据在最该生效的时刻恒为真、永不触发。
/// 3. 验证修复效果**必须肉眼/截图确认**,AX 回读会假阳性(见上文"影子控件")。
///
/// ## 本地实测(2026-09, Flutter 3.44.0, 富文本编辑器场景)
///
/// - 注入形态(只投带 Command 的 V keyDown):补丁命中 → 文本正常落入编辑器;
///   未打补丁时输入框完全无反应(0 字符),与用户反馈的"语音输入法用不了"一致。
/// - 规矩形态(投了完整 flagsChanged 的 Cmd+V,等价物理键盘):判据不成立 → 放行,
///   无多余插入、无双重粘贴。
/// - 复现工具:`CGEvent(keyboardEventSource:virtualKey:9,keyDown:)` + `flags = .maskCommand`,
///   post 到 `.cghidEventTap`。**别顺手补 flagsChanged** —— 那样复现出来的是能正常
///   工作的形态,排查时在这上面绕过弯路。
///
/// ## 退场条件
///
/// 上游修复(HardwareKeyboard 采纳 keyDown 自带 flags,或 embedder 为合成事件补齐
/// 修饰键同步)落地后,本文件连同 MainFlutterWindow 里的 install/uninstall 调用
/// 一并删除即可。回归验证:语音输入法注入一次粘贴,文本正常落入编辑器。
final class SyntheticPasteFix {
  /// V 键的虚拟键码(kVK_ANSI_V)。
  private static let keyCodeV: UInt16 = 9

  private var monitor: Any?

  /// 事件流里是否出现过真正的 flagsChanged Command。
  ///
  /// 这是区分"物理/规矩注入"与"框架会丢掉的合成事件"的唯一可靠判据 ——
  /// 它跟踪的正是 Flutter `HardwareKeyboard` 自己所依赖的那条信息源。
  private var commandSeenInEventStream = false

  /// 安装事件监听。需在主线程调用(AppKit 事件监听要求)。
  func install() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .flagsChanged]
    ) { [weak self] event in
      guard let self else { return event }
      return self.handle(event)
    }
  }

  func uninstall() {
    if let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
  }

  deinit {
    // deinit 可能不在主线程,但 removeMonitor 要求主线程;这里同步派发。
    if let monitor {
      if Thread.isMainThread {
        NSEvent.removeMonitor(monitor)
      } else {
        DispatchQueue.main.sync { NSEvent.removeMonitor(monitor) }
      }
    }
  }

  /// 返回 nil = 吞掉事件(不再交给 Flutter);返回 event = 放行走原路径。
  private func handle(_ event: NSEvent) -> NSEvent? {
    if event.type == .flagsChanged {
      // 记录框架能看见的修饰键状态变化。物理按键与规矩的合成注入都会走到这里,
      // 于是后续的 Cmd+V 判据不成立,保持原路径。
      commandSeenInEventStream = event.modifierFlags.contains(.command)
      return event
    }

    // 只接管"Command 仅存在于事件 flags、事件流中没有对应 flagsChanged"的 Cmd+V。
    guard event.modifierFlags.contains(.command),
          !commandSeenInEventStream,
          isPasteShortcut(event)
    else {
      return event
    }

    guard insertClipboardTextIntoFocusedClient(window: event.window) else {
      // 剪贴板没有文本(如纯图片),或找不到输入客户端 —— 放行,别把事件黑洞掉。
      return event
    }
    return nil
  }

  private func isPasteShortcut(_ event: NSEvent) -> Bool {
    // keyCode 优先(不受布局影响);charactersIgnoringModifiers 作兜底。
    if event.keyCode == Self.keyCodeV { return true }
    return event.charactersIgnoringModifiers?.lowercased() == "v"
  }

  /// 读剪贴板文本,经 IME 通道交给当前输入客户端。成功返回 true。
  private func insertClipboardTextIntoFocusedClient(window: NSWindow?) -> Bool {
    guard let text = NSPasteboard.general.string(forType: .string),
          !text.isEmpty
    else {
      return false
    }

    let responder = (window ?? NSApp.keyWindow)?.firstResponder
    // 解析链终点是 FlutterTextInputPlugin —— 系统听写用的同一条
    // insertText:replacementRange: 通道,框架侧转发完整,IME/composing 行为不受影响。
    let client =
      (responder as? NSTextInputClient)
      ?? (responder as? NSView)?.inputContext?.client
      ?? NSTextInputContext.current?.client
    guard let client else { return false }

    client.insertText(
      text,
      replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    return true
  }
}
