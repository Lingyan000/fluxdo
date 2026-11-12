#ifndef RUNNER_PLUGIN_FILE_ACTIVATION_H_
#define RUNNER_PLUGIN_FILE_ACTIVATION_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

bool ForwardPluginFilesToInstance(gchar** arguments);
void RegisterPluginFiles(FlView* view, GtkWindow* window);
void DisposePluginFiles();

#endif
