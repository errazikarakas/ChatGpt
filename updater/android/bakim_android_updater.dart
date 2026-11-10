import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'bakim_update_feed.dart';

/// Checks once per process. Network, rejection and installer failures never
/// prevent remote assistance or redirect the client to an upstream server.
class BakimAndroidUpdater {
  static const _channel = MethodChannel('bakim.tr/yardim-updater');
  static bool _started = false;
  static bool Function()? isBusy;
  static bool _busy() { try { return isBusy?.call() ?? true; } catch (_) { return true; } }
  static Future<void> checkAtStartup() async {
    if (!Platform.isAndroid || _started) return;
    _started = true;
    _channel.setMethodCallHandler((call) async => call.method == 'canInstallNow' ? !_busy() : null);
    await Future<void>.delayed(const Duration(seconds: 2));
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    http.userAgent = 'Bakim.TR-Yardim/Android-Updater';
    File? partial;
    try {
      final info = Map<String, dynamic>.from(await _channel.invokeMethod('info') as Map);
      if (info['packageName'] != bakimPackageName || info['certificateSha256'] != bakimPublisherCertificate) return;
      // Developer emulator updates may use a dedicated signed fixture feed.
      // Release builds use only the fixed production URL and key above.
      const fixtureHash = String.fromEnvironment('BAKIM_UPDATER_TEST_FIXTURE_SHA256');
      const platform = String.fromEnvironment('BAKIM_UPDATER_PLATFORM', defaultValue: 'android-arm64');
      var fixture = '';
      if (fixtureHash.isNotEmpty) {
        fixture = (await File('${info['cacheDirectory']}/fixture.token').readAsString()).trim();
        if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(fixture) || crypto.sha256.convert(fixture.codeUnits).toString() != fixtureHash) return;
      }
      final feed = Uri.parse(bakimFeedUrl).replace(queryParameters: {'platform': 'android', if (fixture.isNotEmpty) 'fixture': fixture});
      if (!bakimAllowedUrl(feed, feed: true, fixture: fixture)) return;
      final response = await _get(http, feed, feed: true, fixture: fixture);
      if (response.statusCode != HttpStatus.ok) return;
      final bytes = <int>[];
      await for (final part in response.timeout(const Duration(seconds: 5))) {
        bytes.addAll(part);
        if (bytes.length > 65536) throw const FormatException('Feed too large');
      }
      final release = await bakimVerifyFeed(bytes,
        currentVersionCode: info['versionCode'] as int,
        sdkInt: info['sdkInt'] as int, platform: platform, fixture: fixture);
      if (release == null || info['deferUpdatesUntil'] is int &&
          (info['deferUpdatesUntil'] as int) > DateTime.now().millisecondsSinceEpoch) return;
      if (_busy()) return;
      final folder = Directory(info['cacheDirectory'] as String);
      await folder.create(recursive: true);
      final apk = File('${folder.path}/bakim-${release.versionCode}.apk');
      if (!await _matches(apk, release)) {
        partial = File('${apk.path}.partial');
        if (await partial.exists()) await partial.delete();
        final download = await _get(http, release.url, fixture: fixture);
        if (download.statusCode != HttpStatus.ok || download.contentLength > release.size) throw const HttpException('Update unavailable');
        final sink = partial.openWrite();
        var count = 0;
        final deadline = DateTime.now().add(const Duration(minutes: 3));
        try {
          await for (final chunk in download.timeout(const Duration(seconds: 15))) {
            if (DateTime.now().isAfter(deadline)) throw TimeoutException('Update download timed out');
            count += chunk.length;
            if (count > release.size) throw const FormatException('Update exceeds signed size');
            sink.add(chunk);
          }
          await sink.flush();
        } finally { await sink.close(); }
        if (count != release.size || !await _matches(partial, release)) throw const FormatException('Update checksum mismatch');
        if (await apk.exists()) await apk.delete();
        await partial.rename(apk.path); partial = null;
      }
      // Keep the verified APK for a later opening; never replace a live remote
      // assistance session merely because its background download completed.
      if (_busy()) return;
      await _channel.invokeMethod('install', <String, dynamic>{
        'fileName': 'bakim-${release.versionCode}.apk',
        'versionCode': release.versionCode, 'sha256': release.sha256,
        'size': release.size, 'certificateSha256': bakimPublisherCertificate,
      });
    } catch (_) {
      // Offline, expired/bad feed, declined installation: keep the current app.
    } finally {
      http.close(force: true);
      if (partial != null) { try { if (await partial.exists()) await partial.delete(); } catch (_) {} }
    }
  }

  static Future<HttpClientResponse> _get(HttpClient client, Uri uri, {bool feed = false, String fixture = ''}) async {
    // Even redirects stay on the exact allowlisted origin and endpoint.
    for (var redirects = 0; redirects < 4; redirects++) {
      if (!bakimAllowedUrl(uri, feed: feed, fixture: fixture)) throw const FormatException('Update redirect rejected');
      final request = await client.getUrl(uri).timeout(const Duration(seconds: 5));
      request.followRedirects = false;
      final response = await request.close().timeout(const Duration(seconds: 10));
      if (!response.isRedirect) return response;
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>().timeout(const Duration(seconds: 5));
      if (location == null) throw const FormatException('Invalid redirect');
      uri = uri.resolve(location);
    }
    throw const FormatException('Too many update redirects');
  }

  static Future<bool> _matches(File file, BakimUpdateRelease release) async {
    if (!await file.exists() || await file.length() != release.size) return false;
    return (await crypto.sha256.bind(file.openRead()).first).toString() == release.sha256;
  }
}
