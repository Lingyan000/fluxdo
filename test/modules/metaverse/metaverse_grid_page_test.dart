import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/modules/metaverse/plugin/ui/metaverse_widget_library.dart';
import 'package:rfw/formats.dart';
import 'package:rfw/rfw.dart';

void main() {
  for (final mode in MetaverseTileGridLayout.values) {
    testWidgets('长网格 ${mode.name} 只请求可见图片，滚动分页并保持布局', (tester) async {
      tester.view.physicalSize = const Size(390,700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final requested=<String>{};
      var more=0;
      final runtime=Runtime()
        ..update(metaverseWidgetLibraryName,createMetaverseWidgetLibrary(loadImage:(uri) async {
          requested.add(uri.path);return Uint8List(0);
        }))
        ..update(metaversePluginLibraryName,parseLibraryFile('''
          import fluxdo;
          widget Grid = GridPage(layout: data.layout, columns: 2, hasMore: true,
            onLoadMore: event "more" {}, items: [...for item in data.items:
              Surface(padding: [0.0], child: Column(children: [
                Image(url: item.url, height: item.height), Label(text: item.title)
              ]))]);
        '''));
      addTearDown(runtime.dispose);
      final data=DynamicContent({'layout':mode.name,'items':List.generate(100,(i)=>{
        'url':'https://images.example/$i','title':'Item $i','height': i.isEven ? 110.0 : 170.0,
      })});
      await tester.pumpWidget(TranslationProvider(child:MaterialApp(home:Scaffold(body:RemoteWidget(
        runtime:runtime,widget:const FullyQualifiedWidgetName(metaversePluginLibraryName,'Grid'),data:data,
        onEvent:(name,args){if(name=='more')more++;},
      )))));
      await tester.pumpAndSettle();
      expect(requested.length,lessThan(20));
      expect(requested.contains('/99'),isFalse);
      await tester.scrollUntilVisible(find.text('Item 99'),500,scrollable:find.byType(Scrollable).first,maxScrolls:70);
      await tester.drag(find.byType(CustomScrollView),const Offset(0,-250));
      await tester.pumpAndSettle();
      expect(requested.contains('/99'),isTrue);
      expect(more,1);
      expect(tester.takeException(),isNull);
    });
  }
}
