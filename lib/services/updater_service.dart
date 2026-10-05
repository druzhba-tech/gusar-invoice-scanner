import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final String releaseNotes;

  UpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.releaseNotes,
  });
}

class UpdaterService {
  static final UpdaterService _instance = UpdaterService._internal();
  factory UpdaterService() => _instance;
  UpdaterService._internal();

  static const String repoOwner = 'dehagusar-png';
  static const String repoName = 'gusar-invoice-scanner';

  // Проверка наличия обновлений на GitHub Releases
  Future<UpdateInfo?> checkForUpdate() async {
    try {
      final currentInfo = await PackageInfo.fromPlatform();
      final currentVersion = currentInfo.version;

      final url = Uri.parse('https://api.github.com/repos/$repoOwner/$repoName/releases/latest');
      final response = await http.get(url, headers: {'User-Agent': 'Gusar-Scanner-App'});

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final tag = data['tag_name']?.toString().replaceAll('v', '') ?? '1.0.0';
        final body = data['body']?.toString() ?? 'Новая версия приложения';

        // Ищем APK файл в assets
        final assets = data['assets'] as List<dynamic>? ?? [];
        String? apkUrl;
        for (var asset in assets) {
          if (asset['name'].toString().endsWith('.apk')) {
            apkUrl = asset['browser_download_url'];
            break;
          }
        }

        if (apkUrl != null && _isNewer(tag, currentVersion)) {
          return UpdateInfo(
            version: tag,
            downloadUrl: apkUrl,
            releaseNotes: body,
          );
        }
      }
    } catch (e) {
      print('Update check error: $e');
    }
    return null;
  }

  bool _isNewer(String remote, String current) {
    // Простое сравнение версий 1.0.1 > 1.0.0
    return remote.compareTo(current) > 0;
  }

  Future<void> launchDownload(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
