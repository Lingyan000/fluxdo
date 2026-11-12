#ifndef RUNNER_PLUGIN_FILE_ACTIVATION_H_
#define RUNNER_PLUGIN_FILE_ACTIVATION_H_

#include <windows.h>
#include <flutter/binary_messenger.h>
#include <string>
#include <vector>

bool ForwardPluginFilesToInstance(const std::vector<std::string>& arguments);
void RegisterPluginFiles(flutter::BinaryMessenger* messenger);
void DisposePluginFiles();
bool ReceivePluginFileMessage(UINT message, LPARAM parameter);

#endif
