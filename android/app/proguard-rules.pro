# Firebase 根据清单里的类名反射调用无参构造函数来注册组件。
-keep class * implements com.google.firebase.components.ComponentRegistrar {
    public <init>();
}
