# 7.1.0
* New installation method that uses ```PackageInstaller``` (opt-in)
  * Support for silent update of system apps (frananleo)
  * New statuses are published for ```PackageInstaller``` method
* Fixed bug when status is stuck at ```DOWNLOADING``` forewer if server providing apk crashes.
# 7.0.2
* Migration to flutter 3.32
# 7.0.1
* Removed requesting external storage permissions as ota_update no longer requires this permission. Instead it uses internal storage
# 7.0.0
* Migration to flutter 3.29
# 6.0.0
* Migration to flutter 3.16 and graddle wrapper 8.0+ (evgfilim1)
* Ability to cancel ongoing download (JustSayBien)
# 5.1.0
* Added new method call ```getAbi``` to simplify for checking for ABI platform in case of using split apks
# 5.0.0
* Removed legacy support for android flutter v1 embedding
# 4.0.3
* Fixed permission error on Android 13 (TechGeekD)
# 4.0.2
* Fixed check for parent directory existence (thinktkj)
* Correctly reporting error to upstram on download crash
#4.0.1
* Fixed remmant code after cleanup for version 4.0.0
#4.0.0
* Replaced android download manager with OkHttp
* Minor code refactoring
* APKs are no long saved in downloads folder but in internal app storage. This prevents weird permission errors.
* See README.md for details about upgrade.
#3.1.1
* Gradle upgrade
# 3.1.0
* Supporting flutter embedding v2
* Minor refactoring to improve code readability
# 3.0.2
* checking if file is downloaded before running update, because download manager reports canceled download as done. This is not 100% solution, and fails if there is file with same name but it will solve some of the crashes on failed downloads. Please note that if you suply sha256 sum of the file plugin will verify integrity of the downloaded file.
# 3.0.1
* removed old deprectated localization file
# 3.0.0
* Stable release of null safety
# 3.0.0-nullsafety
* Null-safety migration
## 2.4.1
* Fixed null pointer when passing null as checksum or filename (chronm)
## 2.4.0
* Fixed a problem with not receiving error events from stream
* Added ability to validate SHA-256 checksum of downloaded file (android only)
* Added more documentation comments
## 2.3.0
* Added support of sending headers (by vasilich6107)
## 2.2.1
* Intent to install downloaded APK is now dispatched before dispatching ```INSTALLING``` event to flutter. This change should solve race condition if application programatically exits on ```INSTALLING``` event (APP could exit before intent was dispatched and installation would not start in that case).
## 2.2.0
* Reporting of download errors
## 2.1.1
* Added flag FLAG_ACTIVITY_NEW_TASK to intent ACTION_INSTALL_PACKAGE in Android implementation
## 2.1.0
* Added support for custom filename
## 2.0.3
* Updated example to AndroidX
* Updated link to APK used in example
* Improved logging in Android implementation
* Fixed negative progress values in case of big APK
## 2.0.2
* Fixed division by zero error
## 2.0.1
* fixed crash in case of missing `progressSink`
## 2.0.0
* fixed crash on flutter 1.7 (by kmtong)
* added ability to override provider authority (by kmtong)
* changed default authority to be dynamic to support multiple apps with ``ota_update`` out of the box. Please note that this is **breaking change**. To migrate plase update your provider authority in ``AndroidManifest`` to ``${applicationId}.ota_update_provider``

## 1.0.3
* fixed compatibility for older Android APIs (by zileyuan)

## 1.0.2
* ios syntax error fix (by tchunwei)

## 1.0.1
* migration of embeded example to AndroidX
* Upgraded Gradle to latest version

## 1.0.0
* migration to AndroidX and boost compileVersion to 28 (by tchunwei)

## 0.1.3
* extended Android FileProvider to prevent possible conflicts with other plugins that also use FileProvider.

## 0.1.2

* fixing NullPointerException when onRequestPermissionsResult was triggered by different plugin than this one

## 0.1.1

* refactor to use streams only as communication channel
* documentation changes

## 0.1.0

* Initial release
