import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils/top_notification.dart';

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final String releaseNotes;
  final DateTime? publishedAt;

  UpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.releaseNotes,
    this.publishedAt,
  });
}

class UpdaterService {
  static final UpdaterService _instance = UpdaterService._internal();
  factory UpdaterService() => _instance;
  UpdaterService._internal();

  static const String repoOwner = 'druzhba-tech';
  static const String repoName = 'gusar-invoice-scanner';

  UpdateInfo? lastDetectedUpdate;
  String? downloadedApkPath;

  // Получить текущую установленную версию приложения
  Future<String> getCurrentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      return '1.0.4';
    }
  }

  // 1. Проверка наличия обновлений на GitHub Releases с гарантированным выбором САМОЙ ПОСЛЕДНЕЙ версии
  Future<UpdateInfo?> checkForUpdate() async {
    try {
      final currentInfo = await PackageInfo.fromPlatform();
      final currentVersion = currentInfo.version;
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      final reqHeaders = {
        'User-Agent': 'Gusar-Scanner-App',
        'Accept': 'application/vnd.github.v3+json',
        'Cache-Control': 'no-cache, no-store, must-revalidate',
        'Pragma': 'no-cache',
        'Expires': '0',
      };

      // 1. Запрашиваем список всех последних релизов (per_page=20), чтобы найти абсолютный максимум версий
      final listUrl = Uri.parse('https://api.github.com/repos/$repoOwner/$repoName/releases?per_page=20&t=$timestamp');
      http.Response? response;
      try {
        response = await http.get(listUrl, headers: reqHeaders).timeout(const Duration(seconds: 10));
      } catch (e) {
        debugPrint('Releases list fetch error: $e');
      }

      List<dynamic> releasesList = [];
      if (response != null && response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is List) {
          releasesList = decoded;
        }
      }

      // 2. Fallback на эндпоинт releases/latest, если список недоступен
      if (releasesList.isEmpty) {
        final latestUrl = Uri.parse('https://api.github.com/repos/$repoOwner/$repoName/releases/latest?t=$timestamp');
        final latestResp = await http.get(latestUrl, headers: reqHeaders).timeout(const Duration(seconds: 10));
        if (latestResp.statusCode == 200) {
          final decoded = jsonDecode(latestResp.body);
          if (decoded is Map<String, dynamic>) {
            releasesList = [decoded];
          }
        }
      }

      if (releasesList.isEmpty) {
        return null;
      }

      // 3. Отфильтровываем черновики (draft)
      final validReleases = releasesList.where((r) {
        if (r is! Map<String, dynamic>) return false;
        final isDraft = r['draft'] == true;
        return !isDraft;
      }).cast<Map<String, dynamic>>().toList();

      if (validReleases.isEmpty) return null;

      // 4. Сортируем все релизы строго по семантической версии по убыванию (наивысшая версия ПЕРВОЙ)
      validReleases.sort((a, b) {
        final tagA = (a['tag_name']?.toString() ?? '').replaceAll(RegExp(r'^[vV]'), '');
        final tagB = (b['tag_name']?.toString() ?? '').replaceAll(RegExp(r'^[vV]'), '');
        return compareVersions(tagB, tagA); // tagB > tagA => положительно => b идет перед a
      });

      // 5. Берем ТОЛЬКО абсолютную максимальную (самую свежую) версию из всех
      final highestRelease = validReleases.first;
      final highestTag = (highestRelease['tag_name']?.toString() ?? '1.0.0').replaceAll(RegExp(r'^[vV]'), '');
      final body = highestRelease['body']?.toString() ?? 'Доступно плановое обновление приложения GScan.';
      final publishedStr = highestRelease['published_at']?.toString();
      DateTime? publishedAt;
      if (publishedStr != null) {
        publishedAt = DateTime.tryParse(publishedStr);
      }

      // 6. Ищем APK файл именно для этой наивысшей версии
      final assets = highestRelease['assets'] as List<dynamic>? ?? [];
      String? apkUrl;
      for (var asset in assets) {
        final name = asset['name']?.toString() ?? '';
        if (name.endsWith('.apk')) {
          apkUrl = asset['browser_download_url'];
          break;
        }
      }

      apkUrl ??= 'https://github.com/$repoOwner/$repoName/releases/download/v$highestTag/Gusar-Scanner.apk';

      // 7. Сравниваем максимальную найденную версию с текущей версией приложения
      if (_isNewer(highestTag, currentVersion)) {
        lastDetectedUpdate = UpdateInfo(
          version: highestTag,
          downloadUrl: apkUrl,
          releaseNotes: body,
          publishedAt: publishedAt,
        );
        return lastDetectedUpdate;
      }
    } catch (e) {
      debugPrint('Update check warning: $e');
    }
    return null;
  }

  // Сравнение версий: 1 если v1 > v2, -1 если v1 < v2, 0 если равны
  int compareVersions(String v1, String v2) {
    try {
      final v1Clean = v1.split('-').first.replaceAll(RegExp(r'[^0-9.]'), '');
      final v2Clean = v2.split('-').first.replaceAll(RegExp(r'[^0-9.]'), '');

      final v1Parts = v1Clean.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      final v2Parts = v2Clean.split('.').map((e) => int.tryParse(e) ?? 0).toList();

      final maxLen = v1Parts.length > v2Parts.length ? v1Parts.length : v2Parts.length;
      for (int i = 0; i < maxLen; i++) {
        final p1 = i < v1Parts.length ? v1Parts[i] : 0;
        final p2 = i < v2Parts.length ? v2Parts[i] : 0;
        if (p1 > p2) return 1;
        if (p1 < p2) return -1;
      }
      return 0;
    } catch (_) {
      return v1.compareTo(v2);
    }
  }

  // 2. Сравнение версий
  bool _isNewer(String remote, String current) {
    return compareVersions(remote, current) > 0;
  }

  // 3. Скачивание APK с умной докачкой (Range / Resume) и защитой от обрывов сети
  Future<String?> downloadApk({
    required String downloadUrl,
    required String version,
    required Function(double progress, int receivedBytes, int totalBytes, String? statusMsg) onProgress,
    CancelToken? cancelToken,
  }) async {
    final dir = await getTemporaryDirectory();

    // Удаляем любые старые скачанные APK промежуточных версий
    try {
      final entries = dir.listSync();
      for (var entity in entries) {
        if (entity is File && entity.path.contains('Gusar-Scanner') && !entity.path.endsWith('v$version.apk')) {
          try { entity.deleteSync(); } catch (_) {}
        }
      }
    } catch (_) {}

    final filePath = '${dir.path}/Gusar-Scanner-v$version.apk';
    final file = File(filePath);

    // Если файл уже скачан полностью
    if (await file.exists() && await file.length() > 50 * 1024 * 1024) {
      final len = await file.length();
      onProgress(1.0, len, len, 'Файл уже скачан');
      downloadedApkPath = filePath;
      return filePath;
    }

    final dio = Dio();
    int retries = 0;
    const maxRetries = 10;

    while (retries < maxRetries) {
      IOSink? fileSink;
      try {
        int existingBytes = 0;
        if (await file.exists()) {
          existingBytes = await file.length();
        }

        final Map<String, dynamic> reqHeaders = {};
        if (existingBytes > 0) {
          reqHeaders['Range'] = 'bytes=$existingBytes-';
        }

        final response = await dio.get<ResponseBody>(
          downloadUrl,
          options: Options(
            responseType: ResponseType.stream,
            followRedirects: true,
            validateStatus: (status) => status != null && status >= 200 && status < 400,
            headers: reqHeaders,
          ),
          cancelToken: cancelToken,
        );

        final statusCode = response.statusCode ?? 200;
        int totalBytes = 0;

        if (statusCode == 206) {
          // Сервер подтвердил Range-докачку
          final contentRange = response.headers.value('content-range');
          if (contentRange != null && contentRange.contains('/')) {
            totalBytes = int.tryParse(contentRange.split('/').last.trim()) ?? 0;
          }
          if (totalBytes <= 0) {
            final remain = int.tryParse(response.headers.value('content-length') ?? '') ?? 0;
            totalBytes = existingBytes + remain;
          }
          fileSink = file.openWrite(mode: FileMode.append);
        } else {
          // Сервер начал отдавать файл с нуля (200 OK)
          totalBytes = int.tryParse(response.headers.value('content-length') ?? '') ?? 0;
          existingBytes = 0;
          fileSink = file.openWrite(mode: FileMode.write);
        }

        int currentReceived = existingBytes;
        onProgress(
          totalBytes > 0 ? (currentReceived / totalBytes).clamp(0.0, 1.0) : 0.0,
          currentReceived,
          totalBytes,
          null,
        );

        final stream = response.data?.stream;
        if (stream == null) {
          throw Exception('Пустой поток данных');
        }

        await for (final chunk in stream) {
          if (cancelToken?.isCancelled == true) {
            await fileSink.flush();
            await fileSink.close();
            return null;
          }
          fileSink.add(chunk);
          currentReceived += chunk.length;
          onProgress(
            totalBytes > 0 ? (currentReceived / totalBytes).clamp(0.0, 1.0) : 0.0,
            currentReceived,
            totalBytes,
            null,
          );
        }

        await fileSink.flush();
        await fileSink.close();
        fileSink = null;

        final finalLen = await file.length();
        if ((totalBytes > 0 && finalLen >= totalBytes) || (totalBytes <= 0 && finalLen > 40 * 1024 * 1024)) {
          onProgress(1.0, finalLen, finalLen, 'Скачивание завершено');
          downloadedApkPath = filePath;
          return filePath;
        }
      } catch (e) {
        if (fileSink != null) {
          try {
            await fileSink.flush();
            await fileSink.close();
          } catch (_) {}
          fileSink = null;
        }

        if (cancelToken?.isCancelled == true) {
          return null;
        }

        retries++;
        final savedBytes = (await file.exists()) ? await file.length() : 0;
        final savedMb = (savedBytes / (1024 * 1024)).toStringAsFixed(1);
        debugPrint('Download error ($retries/$maxRetries): $e');

        if (retries < maxRetries) {
          onProgress(
            -1.0,
            savedBytes,
            0,
            'Связь прервалась. Авто-докачка с $savedMb МБ через 3 сек...',
          );
          await Future.delayed(const Duration(seconds: 3));
        } else {
          onProgress(
            -2.0,
            savedBytes,
            0,
            'Не удалось загрузить. Нажмите «Повторить», чтобы продолжить с $savedMb МБ.',
          );
          return null;
        }
      }
    }
    return null;
  }

  // 4. Запуск фоновой загрузки через системный Android DownloadManager (в шторке)
  Future<bool> startSystemBackgroundDownload({
    required String downloadUrl,
    required String version,
  }) async {
    try {
      const channel = MethodChannel('tj.gusar.invoice_scanner/app_installer');
      final result = await channel.invokeMethod('startSystemDownload', {
        'url': downloadUrl,
        'title': 'GScan v$version',
        'description': 'Скачивание обновления APK...',
        'fileName': 'Gusar-Scanner-v$version.apk',
      });
      return result != null;
    } catch (e) {
      debugPrint('startSystemBackgroundDownload error: $e');
      await launchDownload(downloadUrl);
      return false;
    }
  }

  // 5. Запуск установки скачанного APK
  Future<bool> installApk(String filePath) async {
    try {
      const channel = MethodChannel('tj.gusar.invoice_scanner/app_installer');
      final result = await channel.invokeMethod<bool>('installApk', {'filePath': filePath});
      return result ?? false;
    } catch (e) {
      debugPrint('Install APK error: $e');
      final uri = Uri.parse('https://github.com/$repoOwner/$repoName/releases/latest');
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return false;
    }
  }

  // 6. Диалог с живым индикатором загрузки, автодокачкой и кнопкой фоновой загрузки
  void showDownloadAndInstallDialog(BuildContext context, UpdateInfo update) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dlgCtx) => _DownloadProgressDialog(
        update: update,
        updater: this,
      ),
    );
  }

  Future<bool> isUpdatePostponed(String version) async {
    final prefs = await SharedPreferences.getInstance();
    final postponedVersion = prefs.getString('postponed_update_version');
    final postponedTime = prefs.getInt('postponed_update_time') ?? 0;

    // Если вышла версия СВЕЖЕЕ отложенной — сразу сбрасываем откладывание!
    if (postponedVersion != null && compareVersions(version, postponedVersion) > 0) {
      await clearPostponedUpdate();
      return false;
    }

    if (postponedVersion == version) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - postponedTime < 12 * 60 * 60 * 1000) {
        return true;
      }
    }
    return false;
  }

  Future<void> postponeUpdate(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('postponed_update_version', version);
    await prefs.setInt('postponed_update_time', DateTime.now().millisecondsSinceEpoch);
  }

  Future<void> clearPostponedUpdate() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('postponed_update_version');
    await prefs.remove('postponed_update_time');
  }

  Future<void> launchDownload(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}

// -------------------------------------------------------------
// Интерактивный диалог скачивания с авто-докачкой и фоновым режимом
// -------------------------------------------------------------
class _DownloadProgressDialog extends StatefulWidget {
  final UpdateInfo update;
  final UpdaterService updater;

  const _DownloadProgressDialog({required this.update, required this.updater});

  @override
  State<_DownloadProgressDialog> createState() => _DownloadProgressDialogState();
}

class _DownloadProgressDialogState extends State<_DownloadProgressDialog> {
  double _progress = 0.0;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  bool _isDownloading = true;
  bool _isDone = false;
  String? _statusMessage;
  String? _error;
  String? _apkPath;
  CancelToken? _cancelToken;

  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    super.dispose();
  }

  void _startDownload() async {
    setState(() {
      _isDownloading = true;
      _error = null;
      _statusMessage = 'Подключение к серверу обновлений...';
    });

    _cancelToken = CancelToken();
    final path = await widget.updater.downloadApk(
      downloadUrl: widget.update.downloadUrl,
      version: widget.update.version,
      cancelToken: _cancelToken,
      onProgress: (prog, received, total, statusMsg) {
        if (!mounted) return;
        setState(() {
          if (prog >= 0) {
            _progress = prog;
            _statusMessage = statusMsg;
            _error = null;
          } else if (prog == -1.0) {
            _statusMessage = statusMsg;
          } else if (prog == -2.0) {
            _error = statusMsg;
            _isDownloading = false;
          }
          if (received > 0) _receivedBytes = received;
          if (total > 0) _totalBytes = total;
        });
      },
    );

    if (mounted) {
      if (path != null) {
        setState(() {
          _isDownloading = false;
          _isDone = true;
          _statusMessage = null;
          _apkPath = path;
        });
      } else if (_error == null) {
        setState(() {
          _isDownloading = false;
          _error = 'Загрузка была остановлена.';
        });
      }
    }
  }

  void _install() {
    if (_apkPath != null) {
      widget.updater.installApk(_apkPath!);
    }
  }

  void _switchToBackgroundDownload() async {
    _cancelToken?.cancel();
    await widget.updater.startSystemBackgroundDownload(
      downloadUrl: widget.update.downloadUrl,
      version: widget.update.version,
    );
    if (mounted) {
      Navigator.pop(context);
      TopNotification.showInfo(
        context,
        'Загрузка продолжается в шторке Android. Можно свернуть или закрыть приложение!',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final percentInt = (_progress * 100).clamp(0, 100).toInt();
    final receivedMb = (_receivedBytes / (1024 * 1024)).toStringAsFixed(1);
    final totalMb = _totalBytes > 0 ? (_totalBytes / (1024 * 1024)).toStringAsFixed(1) : '57.3';

    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _isDone ? const Color(0xFF10B981).withOpacity(0.2) : const Color(0xFF38BDF8).withOpacity(0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              _isDone ? Icons.check_circle_rounded : Icons.download_rounded,
              color: _isDone ? const Color(0xFF10B981) : const Color(0xFF38BDF8),
              size: 26,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isDone ? 'Обновление скачано!' : 'Скачивание обновления',
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Text('Версия v${widget.update.version}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_isDownloading) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                minHeight: 10,
                backgroundColor: Colors.white10,
                color: const Color(0xFF38BDF8),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('$percentInt%', style: const TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold, fontSize: 14)),
                Text('$receivedMb МБ из $totalMb МБ', style: const TextStyle(color: Colors.white60, fontSize: 12)),
              ],
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded, color: Colors.amber, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _statusMessage!,
                        style: const TextStyle(color: Colors.amberAccent, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              const SizedBox(height: 8),
              const Text(
                'Идёт скачивание с поддержкой докачки при сбоях связи...',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
            const SizedBox(height: 14),
            // Кнопка переключения в системную шторку (фоновый режим)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF38BDF8),
                  side: const BorderSide(color: Color(0xFF0284C7)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.downloading_rounded, size: 18),
                label: const Text('Скачать в фоне (в шторке телефона)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                onPressed: _switchToBackgroundDownload,
              ),
            ),
          ] else if (_isDone) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.verified, color: Color(0xFF10B981), size: 28),
                  SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Файл готов к установке', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                        SizedBox(height: 2),
                        Text('Нажмите кнопку ниже, чтобы обновить приложение без потери данных.', style: TextStyle(color: Colors.white70, fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ] else if (_error != null) ...[
            Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.play_arrow_rounded, color: Colors.white),
                    label: Text(
                      _receivedBytes > 0 ? 'Продолжить ($receivedMb МБ)' : 'Повторить',
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    onPressed: _startDownload,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Скачать через шторку Android',
                  icon: const Icon(Icons.downloading_rounded, color: Color(0xFF38BDF8)),
                  onPressed: _switchToBackgroundDownload,
                ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        if (_isDownloading)
          TextButton(
            onPressed: () {
              _cancelToken?.cancel();
              Navigator.pop(context);
            },
            child: const Text('Свернуть', style: TextStyle(color: Colors.white54)),
          )
        else if (!_isDone)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть', style: TextStyle(color: Colors.white54)),
          ),
        if (_isDone)
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.system_update_rounded, color: Colors.white),
            label: const Text('УСТАНОВИТЬ СЕЙЧАС', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            onPressed: () {
              Navigator.pop(context);
              _install();
            },
          ),
      ],
    );
  }
}
