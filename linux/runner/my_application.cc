#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"
#include "desktop_multi_window/desktop_multi_window_plugin.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void focus_flutter_view(GtkWindow* window, GtkWidget* view) {
  if (window == nullptr || view == nullptr) {
    return;
  }

  if (!gtk_widget_get_can_focus(view)) {
    gtk_widget_set_can_focus(view, TRUE);
  }

  gtk_window_set_focus(window, view);
  gtk_widget_grab_focus(view);
}

// 子引擎的窗口不能通过当前进程的活动窗口推断。
static void on_child_window_call(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto weak_view = static_cast<GWeakRef*>(data);
  g_autoptr(GObject) view = static_cast<GObject*>(g_weak_ref_get(weak_view));
  GtkWidget* top = view ? gtk_widget_get_toplevel(GTK_WIDGET(view)) : nullptr;
  if (!GTK_IS_WINDOW(top)) {
    fl_method_call_respond_error(call, "WINDOW_CLOSED", nullptr, nullptr, nullptr);
    return;
  }
  GtkWindow* window = GTK_WINDOW(top);
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  if (g_str_equal(method, "show")) {
    gtk_widget_show(top);
    gtk_window_present(window);
  } else if (g_str_equal(method, "configure") && fl_value_get_type(args) == FL_VALUE_TYPE_STRING) {
    gtk_window_set_title(window, fl_value_get_string(args));
    gtk_widget_set_size_request(top, 420, 320);
    gtk_window_resize(window, 1000, 760);
    gtk_window_set_position(window, GTK_WIN_POS_CENTER);
  } else if (g_str_equal(method, "close")) {
    fl_method_call_respond_success(call, nullptr, nullptr);
    gtk_window_close(window);
    return;
  } else if (g_str_equal(method, "isFullscreen")) {
    auto native_window = gtk_widget_get_window(top);
    g_autoptr(FlValue) value = fl_value_new_bool(native_window &&
        (gdk_window_get_state(native_window) & GDK_WINDOW_STATE_FULLSCREEN));
    fl_method_call_respond_success(call, value, nullptr);
    return;
  } else if (g_str_equal(method, "fullscreen") && fl_value_get_type(args) == FL_VALUE_TYPE_BOOL) {
    if (fl_value_get_bool(args)) gtk_window_fullscreen(window);
    else gtk_window_unfullscreen(window);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  fl_method_call_respond_success(call, nullptr, nullptr);
}

static void on_window_show(GtkWidget* widget, gpointer user_data) {
  focus_flutter_view(GTK_WINDOW(widget), GTK_WIDGET(user_data));
}

static gboolean on_window_focus_in_event(GtkWidget* widget,
                                         GdkEventFocus* event,
                                         gpointer user_data) {
  (void)event;
  focus_flutter_view(GTK_WINDOW(widget), GTK_WIDGET(user_data));
  return FALSE;
}

static void on_window_is_active_changed(GObject* object,
                                        GParamSpec* pspec,
                                        gpointer user_data) {
  (void)pspec;
  GtkWindow* window = GTK_WINDOW(object);
  if (!gtk_window_is_active(window)) {
    return;
  }
  focus_flutter_view(window, GTK_WIDGET(user_data));
}

static gboolean on_view_button_press_event(GtkWidget* widget,
                                           GdkEventButton* event,
                                           gpointer user_data) {
  (void)event;
  focus_flutter_view(GTK_WINDOW(user_data), widget);
  return FALSE;
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "FluxDO");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "FluxDO");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Realize the view so Flutter can start rendering, but keep the toplevel
  // window hidden until Dart restores the saved desktop window state.
  gtk_widget_realize(GTK_WIDGET(view));

  gtk_widget_add_events(GTK_WIDGET(view), GDK_BUTTON_PRESS_MASK);
  g_signal_connect(window, "show", G_CALLBACK(on_window_show), view);
  g_signal_connect(window,
                   "focus-in-event",
                   G_CALLBACK(on_window_focus_in_event),
                   view);
  g_signal_connect(window,
                   "notify::is-active",
                   G_CALLBACK(on_window_is_active_changed),
                   view);
  g_signal_connect(
      view, "button-press-event", G_CALLBACK(on_view_button_press_event), window);

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  desktop_multi_window_plugin_set_window_created_callback([](FlPluginRegistry* registry) {
    fl_register_plugins(registry);
    g_autoptr(FlPluginRegistrar) registrar = fl_plugin_registry_get_registrar_for_plugin(
        registry, "FluxdoMiniAppWindowControls");
    auto weak_view = new GWeakRef;
    g_weak_ref_init(weak_view, fl_plugin_registrar_get_view(registrar));
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
        fl_plugin_registrar_get_messenger(registrar), "com.fluxdo/mini_app_window_controls",
        FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(channel, on_child_window_call, weak_view,
        [](gpointer data) {
          auto ref = static_cast<GWeakRef*>(data);
          g_weak_ref_clear(ref);
          delete ref;
        });
  });

  focus_flutter_view(window, GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
