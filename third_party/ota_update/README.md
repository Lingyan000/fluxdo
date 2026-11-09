# ota_update

[![pub package](https://img.shields.io/pub/v/ota_update.svg)](https://pub.dartlang.org/packages/ota_update)

Flutter plugin implementing OTA update.\
On Android it downloads the file (with progress reporting) and triggers app installation intent.\
On iOS it opens safari with specified ipa url. (not yet functioning)
## Migrating to 7.0.0+
As we plan to use more modern java features across all our plugins, we opted for desugaring of java features. As a result,
you need to enable desugaring. More and more packages is already requiring this, so there is a good chance you have it enabled already.

If not, it is fairly simple [to do so](https://stackoverflow.com/questions/79158012/dependency-flutter-local-notifications-requires-core-library-desugaring-to-be). In you ```android/app/build.gradle```
```
android {
    defaultConfig {
        // Required when setting minSdkVersion to 20 or lower
        multiDexEnabled true
    }

    compileOptions {
        // Flag to enable support for the new language APIs
        coreLibraryDesugaringEnabled true
        // Sets Java compatibility to Java 8
        sourceCompatibility JavaVersion.VERSION_1_8
        targetCompatibility JavaVersion.VERSION_1_8
    }
}

dependencies {
    // For AGP 7.4+
    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.0.3'
    // For AGP 7.3
    // coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:1.2.3'
    // For AGP 4.0 to 7.2
    // coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:1.1.9'
}
```

## Migrating to 5.0.0+
This update removes legacy support for flutter android embedding v1. No one should be affected now. In a rare event you are still using old ombedding, plese consider upgrading to v2.

## Migrating to 4.0.0+
This update solves many problems arising from using android download manager and saving to external downloads folder.

Important changes:
* Files are no longer downloaded using DownloadManager
  * Because we are not using download manager there is no default system notification about progress. Hovewer since update events are published to flutter code, you can implement notification yourself if needed.
* Files are saved in internal directory which eliminates need to use SAF and prevents from multiple applications that uses this package to potentially overwrite apk

After upgrading version number, you need to replace contents of the file ```android/src/main/res/xml/filepaths.xml``` with following contents.
```xml
<?xml version="1.0" encoding="utf-8"?>
<paths xmlns:android="http://schemas.android.com/apk/res/android">
    <files-path name="internal_apk_storage" path="ota_update/"/>
</paths>
```


## Usage

To use this plugin, add `ota_update` as a [dependency in your `pubspec.yaml` file](https://flutter.io/platform-plugins/).

## Example

``` dart
// IMPORT PACKAGE
import 'package:ota_update/ota_update.dart';

  // RUN OTA UPDATE
  // START LISTENING FOR DOWNLOAD PROGRESS REPORTING EVENTS
  try {
      //LINK CONTAINS APK OF FLUTTER HELLO WORLD FROM FLUTTER SDK EXAMPLES
      OtaUpdate()
          .execute(
        'https://internal1.4q.sk/flutter_hello_world.apk',
        // OPTIONAL
        destinationFilename: 'flutter_hello_world.apk',
        //OPTIONAL, ANDROID ONLY - ABILITY TO VALIDATE CHECKSUM OF FILE:
        sha256checksum: "d6da28451a1e15cf7a75f2c3f151befad3b80ad0bb232ab15c20897e54f21478",
      ).listen(
        (OtaEvent event) {
          setState(() => currentEvent = event);
        },
      );
  } catch (e) {
      print('Failed to make OTA update. Details: $e');
  }
```
### Android
Add permissions to AndroidManifest.xml.

```xml
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"/>
<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>
```

#### PackageInstaller method
Since version ```7.1.0``` the plugin supports ```PackageInstaller``` method for installing APKs. This method is default for **system apps** as it allows silent installation (more in next section).

For **regular apps** this includes reporting of installation progress via plugin and notification after installation result (hovewer upon successfull installation, the OS may restart app). One caveat when using this method is that OS no longer provides nice UI with installation progress, so it is more suited for apps that want to handle progress notifications themselves.

Because of this, the ```PackageInstaller``` method is not enabled by default but you need to opt in by passing ```usePackageInstaller: true``` to ```execute``` method.

Plase note, that when you want to ensure progress reporting works as intented you need to add following receiver referrence to AndroidManifest.xml inside ```<application>``` node.

```xml
<receiver android:name="sk.fourq.otaupdate.InstallResultReceiver"  android:exported="false">
    <intent-filter>
        <action android:name="${applicationId}.ACTION_INSTALL_COMPLETE"/>
    </intent-filter>
</receiver>
```
#### Silent Installation (System Apps Only)
This plugin automatically supports silent installation for system apps without user interaction. The plugin includes the `INSTALL_PACKAGES` permission which enables this feature.

**How it works:**
- **Regular apps** (Play Store, sideloaded): Shows standard installation prompt to user ✓
- **System apps** (pre-installed in `/system/` or signed with platform certificate): Installs silently without user interaction ✓

**No extra configuration needed!** The plugin automatically detects if your app is a system app and uses the appropriate installation method. For regular apps, the `INSTALL_PACKAGES` permission is harmlessly ignored by Android and the normal installation flow is used.

This is particularly useful for:
- IoT devices
- Kiosk applications
- Enterprise/MDM deployments
- Custom Android ROM distributions

Add following provider referrence to AndroidManifest.xml inside ```<application>``` node.
```xml
<provider
    android:name="sk.fourq.otaupdate.OtaUpdateFileProvider"
    android:authorities="${applicationId}.ota_update_provider"
    android:exported="false"
    android:grantUriPermissions="true">
    <meta-data
        android:name="android.support.FILE_PROVIDER_PATHS"
        android:resource="@xml/filepaths" />
</provider>
```
Add following receiver referrence to AndroidManifest.xml inside ```<application>``` node.
```xml
<receiver android:name="sk.fourq.otaupdate.InstallResultReceiver"  android:exported="false">
    <intent-filter>
        <action android:name="${applicationId}.ACTION_INSTALL_COMPLETE"/>
    </intent-filter>
</receiver>
```
When using silent installation, or ```PackageInstaller``` method, this allows plugin to get result of installation.

See [AndroidManifest.xml](example/android/app/src/main/AndroidManifest.xml) in example

Also, create the file ```android/src/main/res/xml/filepaths.xml``` with following contents.
This will allow plugin to access the downloads folder to start the update.

```xml
<?xml version="1.0" encoding="utf-8"?>
<paths xmlns:android="http://schemas.android.com/apk/res/android">
<files-path name="internal_apk_storage" path="ota_update/"/>
</paths>
```

See [filepaths.xml](example/android/app/src/main/res/xml/filepaths.xml) in example

### Non-https traffic
Cleartext traffic is disabled by Android download manager by default for security reasons. To [allow](https://stackoverflow.com/questions/51770323/how-to-solve-android-p-downloadmanager-stopping-with-cleartext-http-traffic-to) it you need to create file `res/xml/network_security_config.xml`

```
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config cleartextTrafficPermitted="true" />
</network-security-config>
```

and reference it in `AndroidManifest.xml` in application tag

```
android:networkSecurityConfig="@xml/network_security_config"
```

#### Typical workflow
Since this plugin only handles download and instalation, there are still a few steps out of our scope that needs to be done. This is mainly to allow different implementation scenarios.

1. Update hosting. You need to hava server that provides you with installation file.
2. Checking for update. You need to have a way to check if the update is available.
3. Authentication. If your update server requires login you may need to obtain authorization token (or anything else you are using for auth) before downloading APK.
4. Download and installation of APK. This is the part that is provided for you by plugin.


#### Using sha256checksum
This package supports sha256 checksum verification of the file integrity. This allows as to detect if file has been corrupted durring transfer.
To use this feature, your update server should provide you with sha256 checksum of APK and you need to obtain this value while you are checking for update. When you run ```execute``` method with this parameter, plugin will compute sha256 value from downloaded file and compare with provided value. The update will continiue only if the two values match, otherwise it throws error.

#### Using split apks (experimental)
Plugin now allows you to get android ABI platform. If your are building multiple apks per abi (using flutter param --split-per-abi), you can now utilize smaller APKs. You can get system architecture and choose to download smaller APK

#### Notes
* Google Play Protect may in some cases cause problems with installation.
* For system apps, the plugin supports silent installation without user interaction. Regular apps will continue to show the standard installation prompt.

## Statuses
* DOWNLOADING:
    * status for events during downloading phase
    * event value is download progress percentage
* INSTALLING:
    * event status that is sent just before triggering installation intent
    * event value is always null on first call
    * event value is installation progress percentage when using ```PackageInstaller``` method.
* INSTALLATION_DONE:
    * only sent when using ```PackageInstaller``` method
    * indicates that the update has been successfully installed
* ALREADY_RUNNING_ERROR:
    * sent when the 'execute' method is called before previous run finished
    * event value is null
* INSTALLATION_ERROR:
    * only sent when using ```PackageInstaller``` method
    * indicates that installation resulted in an error
    * some devices may trigger this when the user clicks on cancel, but it is not always the case
* PERMISSION_NOT_GRANTED_ERROR:
    * sent when the user refused to grant required permissions
    * event value is null.
* DOWNLOAD_ERROR
    * sent when download crashed.
* CHECKSUM_ERROR (android only)
    * sent if calculated SHA-256 checksum does not match the provided (optional) value
    * sent if checksum value should be verified, but checksum calculation failed
* INTERNAL_ERROR:
    * sent in all other error cases
    * event value is the underlying error message
* CANCELED:
  * sent when the download was canceled using 'OtaUpdate().cancel()'

## TODO
* restrict download to a specific connection type (mobile, wifi)

## Contribution and Support
* Contributions are welcome!
* If you find a bug or want a feature, please fill an issue
* If you want to contribute code, please create a PR

### PR guidelines

* Please do not change a version in pubspec.yaml nor update CHANGELOG.md - this will be done before release of the new version as release may contain multiple fixes and/or features. This will prevent some potential (yet simple) merge  conflicts.
