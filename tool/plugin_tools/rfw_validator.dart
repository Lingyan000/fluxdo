import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:fluxdo/modules/metaverse/plugin/metaverse_ui_validator.dart';

/// 使用与 App 相同的官方解析器编译给 CLI，插件作者无需安装 Dart/Flutter。
void main() {
  globalContext['fluxdoValidateRfw'] =
      ((JSString text, JSString contract) => jsonEncode(
        validatePluginUiContract(
          text.toDart,
          jsonDecode(contract.toDart) as Map,
        ),
      ).toJS).toJS;
}
