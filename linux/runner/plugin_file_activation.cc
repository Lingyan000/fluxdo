#include "plugin_file_activation.h"

#include <string>
#include <vector>

namespace {
GApplication* file_application = nullptr;
FlMethodChannel* channel = nullptr;
GtkWindow* main_window = nullptr;
std::vector<std::string> pending_files;

bool IsPluginFile(GFile* file) {
  g_autofree gchar* path = g_file_get_path(file);
  if (!path) return false;
  g_autofree gchar* lower = g_ascii_strdown(path, -1);
  return g_str_has_suffix(lower, ".fluxplugin");
}

void OpenFiles(GApplication*, GFile** files, gint count, const gchar*, gpointer) {
  for (gint index = 0; index < count; ++index) {
    if (!IsPluginFile(files[index])) continue;
    g_autofree gchar* uri = g_file_get_uri(files[index]);
    pending_files.emplace_back(uri);
  }
  if (channel && !pending_files.empty()) {
    fl_method_channel_invoke_method(channel, "filesAvailable", nullptr,
                                    nullptr, nullptr, nullptr);
  }
  if (main_window) gtk_window_present(main_window);
}
}  // namespace

bool ForwardPluginFilesToInstance(gchar** arguments) {
  // 独立文件激活通道，主应用保留原有多进程和小程序窗口启动行为。
  file_application = g_application_new(APPLICATION_ID ".PluginFiles",
                                       G_APPLICATION_HANDLES_OPEN);
  g_signal_connect(file_application, "open", G_CALLBACK(OpenFiles), nullptr);
  g_autoptr(GError) error = nullptr;
  if (!g_application_register(file_application, nullptr, &error)) {
    g_warning("Plugin file activation unavailable: %s", error->message);
    g_clear_object(&file_application);
    return false;
  }
  if (!arguments[0] || !g_application_get_is_remote(file_application)) {
    return false;
  }

  g_autoptr(GPtrArray) files = g_ptr_array_new_with_free_func(g_object_unref);
  for (gchar** argument = arguments; *argument; ++argument) {
    GFile* file = g_file_new_for_commandline_arg(*argument);
    if (!IsPluginFile(file)) {
      g_object_unref(file);
      return false;
    }
    g_ptr_array_add(files, file);
  }
  g_application_open(file_application, reinterpret_cast<GFile**>(files->pdata),
                      static_cast<gint>(files->len), "");
  g_dbus_connection_flush_sync(g_application_get_dbus_connection(file_application),
                               nullptr, nullptr);
  return true;
}

void RegisterPluginFiles(FlView* view, GtkWindow* window) {
  main_window = window;
  g_object_add_weak_pointer(G_OBJECT(window), reinterpret_cast<gpointer*>(&main_window));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  channel = fl_method_channel_new(fl_engine_get_binary_messenger(fl_view_get_engine(view)),
                                  "com.fluxdo/plugin_files", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel, [](FlMethodChannel*, FlMethodCall* call, gpointer) {
        if (g_strcmp0(fl_method_call_get_name(call), "takePendingFiles") != 0) {
          fl_method_call_respond_not_implemented(call, nullptr);
          return;
        }
        g_autoptr(FlValue) files = fl_value_new_list();
        for (const auto& path : pending_files) {
          fl_value_append_take(files, fl_value_new_string(path.c_str()));
        }
        pending_files.clear();
        fl_method_call_respond_success(call, files, nullptr);
      }, nullptr, nullptr);
}

void DisposePluginFiles() {
  if (main_window) {
    g_object_remove_weak_pointer(G_OBJECT(main_window), reinterpret_cast<gpointer*>(&main_window));
    main_window = nullptr;
  }
  g_clear_object(&channel);
  g_clear_object(&file_application);
}
