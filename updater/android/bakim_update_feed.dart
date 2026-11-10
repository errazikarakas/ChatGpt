import 'dart:convert';
import 'package:cryptography/cryptography.dart';

const bakimFeedUrl = 'https://xn--bakm-nza.tr/yardim-guncelle.php?platform=android';
const bakimUpdateKeyId = 'bakim-yardim-2026';
const bakimUpdatePublicKey = 'dS7jt4SMbs05q2Od0C5btJQbh9BjBhQWcS2d6gQwPt0=';
const bakimPublisherCertificate = '8965892c1419f7bcdead4dc152c8b2916d43e3a8e71521cd7e0ac4d6333e7341';
const bakimPackageName = 'tr.bakim.yardim';

class BakimUpdateRelease {
  final String version;
  final int versionCode;
  final Uri url;
  final String sha256;
  final int size;
  final int minSdk;
  BakimUpdateRelease(this.version, this.versionCode, this.url, this.sha256, this.size, this.minSdk);
}

bool bakimAllowedUrl(Uri uri, {bool feed = false, String fixture = ''}) {
  if (!(uri.scheme == 'https' && uri.host == 'xn--bakm-nza.tr' &&
    uri.port == 443 && uri.userInfo.isEmpty && !uri.hasFragment &&
    uri.path == (feed ? '/yardim-guncelle.php' : '/yardim-paket.php'))) return false;
  final query = uri.queryParametersAll;
  final allowed = <String>{'platform', if (!feed) 'versionCode', if (fixture.isNotEmpty) 'fixture'};
  if (query.keys.any((key) => !allowed.contains(key)) || query.values.any((values) => values.length != 1) || query['platform']?.single != 'android') return false;
  if (!feed && !RegExp(r'^[0-9]{1,10}$').hasMatch(query['versionCode']?.single ?? '')) return false;
  if (fixture.isNotEmpty && (!RegExp(r'^[0-9a-f]{32}$').hasMatch(fixture) || query['fixture']?.single != fixture)) return false;
  return true;
}

/// Signature covers the exact decoded bytes; JSON is never reserialized.
Future<BakimUpdateRelease?> bakimVerifyFeed(
  List<int> envelopeBytes, {required int currentVersionCode, required int sdkInt,
  DateTime? now, String publicKey = bakimUpdatePublicKey,
  String platform = 'android-arm64',
  String fixture = '',
}) async {
  if (envelopeBytes.length > 65536) throw const FormatException('Feed too large');
  final envelope = jsonDecode(utf8.decode(envelopeBytes)) as Map<String, dynamic>;
  if (envelope['keyId'] != bakimUpdateKeyId || envelope['payload'] is! String || envelope['signature'] is! String) {
    throw const FormatException('Unknown signing key');
  }
  final payload = base64Decode(envelope['payload'] as String);
  final signatureBytes = base64Decode(envelope['signature'] as String);
  final keyBytes = base64Decode(publicKey);
  if (payload.length > 32768 || signatureBytes.length != 64 || keyBytes.length != 32) throw const FormatException('Invalid signature size');
  final signature = Signature(signatureBytes, publicKey: SimplePublicKey(keyBytes, type: KeyPairType.ed25519));
  if (!await Ed25519().verify(payload, signature: signature)) throw const FormatException('Invalid update signature');
  final data = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
  if (fixture.isEmpty ? data.containsKey('fixture') : data['fixture'] != fixture) throw const FormatException('Fixture feed rejected');
  if (data['schema'] != 1 || data['product'] != 'Bakim.TR Yardim' ||
      data['platform'] != platform || data['channel'] != 'stable' ||
      data['packageName'] != bakimPackageName || data['certificateSha256'] != bakimPublisherCertificate) {
    throw const FormatException('Update target mismatch');
  }
  final version = data['version']; final code = data['versionCode'];
  final size = data['size']; final minSdk = data['minSdk']; final digest = data['sha256'];
  if (version is! String || version.isEmpty || version.length > 80 ||
      code is! int || code < 1 || code > 2147483647 || size is! int || size < 1024 || size > 160 * 1024 * 1024 ||
      minSdk is! int || minSdk < 22 || minSdk > 100 || digest is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
    throw const FormatException('Invalid release metadata');
  }
  final url = Uri.parse(data['url'] as String);
  if (!bakimAllowedUrl(url, fixture: fixture) || url.queryParameters['platform'] != 'android' ||
      url.queryParameters['versionCode'] != code.toString()) throw const FormatException('Update URL rejected');
  final published = DateTime.parse(data['publishedAt'] as String).toUtc();
  final issued = DateTime.parse(data['issuedAt'] as String).toUtc();
  final expires = DateTime.parse(data['expiresAt'] as String).toUtc();
  final time = (now ?? DateTime.now()).toUtc();
  if (!expires.isAfter(time) || !expires.isAfter(issued) ||
      published.isAfter(time.add(const Duration(minutes: 10))) ||
      issued.isAfter(time.add(const Duration(minutes: 10))) ||
      expires.difference(issued) > const Duration(days: 32)) throw const FormatException('Expired update feed');
  if (code <= currentVersionCode || minSdk > sdkInt) return null;
  return BakimUpdateRelease(version, code, url, digest, size, minSdk);
}
