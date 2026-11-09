// 保留上游公开枚举名称及通道序号，兼容现有调用方。
// ignore_for_file: constant_identifier_names

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// Flutter plugin implementing OTA update
/// On Android it downloads the file (with progress reporting) and triggers app installation intent.
/// On iOS it opens safari with specified ipa url. (not yet functioning)
class OtaUpdate {
  static const EventChannel _progressChannel = EventChannel(
    'sk.fourq.ota_update/stream',
  );
  static const MethodChannel _methodChannel = MethodChannel(
    'sk.fourq.ota_update/method',
  );
  Stream<OtaEvent>? _progressStream;

  /// Get most preffered abi platform. Use if you are using
  /// split-apk
  Future<String?> getAbi() async {
    return _methodChannel.invokeMethod<String>('getAbi');
  }

  /// Cancel the currently active ota download if there is one
  Future<void> cancel() async {
    return _methodChannel.invokeMethod<void>('cancel');
  }

  /// Execute download and instalation of the plugin.
  /// Download progress and all success or error states are publish in stream as OtaEvent
  Stream<OtaEvent> execute(
    String url, {
    Map<String, String> headers = const <String, String>{},
    String? androidProviderAuthority,
    String? destinationFilename,
    String? sha256checksum,
    bool usePackageInstaller = false,
    // 系统要求确认且应用位于后台时，显示在安装入口通知中的文案。
    String? confirmationNotificationText,
  }) {
    if (destinationFilename != null && destinationFilename.contains('/')) {
      throw OtaUpdateException('Invalid filename $destinationFilename');
    }
    return _progressStream ??= _progressChannel
        .receiveBroadcastStream(<dynamic, dynamic>{
          'url': url,
          'androidProviderAuthority': androidProviderAuthority,
          'filename': destinationFilename,
          'checksum': sha256checksum,
          'headers': jsonEncode(headers),
          'usePackageInstaller': usePackageInstaller ? 'true' : 'false',
          'confirmationNotificationText': confirmationNotificationText,
        })
        .map((dynamic event) => _toOtaEvent(event.cast<String?>()))
        .transform(
          StreamTransformer<OtaEvent, OtaEvent>.fromHandlers(
            handleError: (
              Object error,
              StackTrace stack,
              EventSink<OtaEvent> sink,
            ) {
              if (error is PlatformException) {
                sink.add(_toOtaEvent(<String?>[error.code, error.message]));
              } else {
                sink.addError(error, stack);
              }
            },
          ),
        );
  }

  OtaEvent _toOtaEvent(List<String?> event) {
    return OtaEvent(OtaStatus.values[int.parse(event[0]!)], event[1]);
  }
}

///Event describing current status
class OtaEvent {
  ///Constructor for OtaEvent
  OtaEvent(this.status, this.value);

  /// Current status as enum value
  OtaStatus status;

  /// Additional status info e.g. percents downloaded or error message (can be null)
  String? value;
}

/// Enum values describing states
enum OtaStatus {
  /// FILE IS BEING DOWNLOADED
  DOWNLOADING,

  /// INSTALLATION HAS BEEN TRIGGERED
  INSTALLING,

  /// INSTALLATION HAS BEEN SUCCESSFULY DONE
  INSTALLATION_DONE,

  /// DOWNLOAD IS ALREADY RUNNING
  ALREADY_RUNNING_ERROR,

  /// INSTALLATION WAS NOT SUCCESSFULL
  INSTALLATION_ERROR,

  /// COULD NOT CONTINUE BECAUSE OF MISSING PERMISSIONS
  PERMISSION_NOT_GRANTED_ERROR,

  /// UNKWNON ERROR. SEE VALUE FOR MORE INFROMATION
  INTERNAL_ERROR,

  /// FILE COULD NOT BE DOWNLOADED. SEE VALUE FOR MORE INFORMATION
  DOWNLOAD_ERROR,

  /// CHECKSUM VERIFICATION FAILED. MOSTLY THIS IS DUE INCORRECT OR CORRUPTED FILE
  /// THIS IS ALSO RETURNED IF PLUGIN WAS UNABLE TO CALCULATE SHA 256 HASH OF DOWNLOADED FILE
  /// SEE VALUE FOR MORE INFORMATION
  CHECKSUM_ERROR,

  /// DOWNLOAD WAS CANCELED
  CANCELED,
}

/// EXCEPTION FOR QUICK IDENTIFICATION OF ERRORS THROWN FROM THIS PLUGIN.
/// THIS IS USED CURRENTLY ONLY FOR INPUT PARAMETER VERIFICATION ERRORS. IF THERE IS PROBLEM WITH
/// DOWNLOADING THE FILE OR RUNNING UPDATE OtaEvent WITH ONE OF THE _ERROR STATUSES IS USED
class OtaUpdateException implements Exception {
  /// DEFAULT CONSTRUCTOR
  OtaUpdateException(this.message);

  /// ERROR MESSAGE
  final String message;

  @override
  String toString() {
    return 'Exception: $message';
  }
}
