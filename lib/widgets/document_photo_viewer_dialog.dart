import 'dart:io';
import 'package:flutter/material.dart';

class DocumentPhotoViewerDialog extends StatefulWidget {
  final List<String> photoPaths;
  final String invoiceNumber;
  final String supplierName;
  final int initialPage;

  const DocumentPhotoViewerDialog({
    super.key,
    required this.photoPaths,
    required this.invoiceNumber,
    required this.supplierName,
    this.initialPage = 0,
  });

  static Future<void> show(
    BuildContext context, {
    required List<String> photoPaths,
    required String invoiceNumber,
    required String supplierName,
    int initialPage = 0,
  }) {
    return showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.9),
      builder: (_) => DocumentPhotoViewerDialog(
        photoPaths: photoPaths,
        invoiceNumber: invoiceNumber,
        supplierName: supplierName,
        initialPage: initialPage,
      ),
    );
  }

  @override
  State<DocumentPhotoViewerDialog> createState() => _DocumentPhotoViewerDialogState();
}

class _DocumentPhotoViewerDialogState extends State<DocumentPhotoViewerDialog> {
  late int _currentPage;
  int _rotationQuarterTurns = 0;
  final TransformationController _transCtrl = TransformationController();

  @override
  void initState() {
    super.initState();
    _currentPage = widget.initialPage;
  }

  @override
  void dispose() {
    _transCtrl.dispose();
    super.dispose();
  }

  double _getFileSizeKb(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) {
        return f.lengthSync() / 1024.0;
      }
    } catch (_) {}
    return 0.0;
  }

  @override
  Widget build(BuildContext context) {
    final validPaths = widget.photoPaths.where((p) => p.isNotEmpty).toList();
    final hasPhotos = validPaths.isNotEmpty;
    final currentPath = hasPhotos && _currentPage < validPaths.length ? validPaths[_currentPage] : null;
    final fileSizeKb = currentPath != null ? _getFileSizeKb(currentPath) : 0.0;
    final fileExists = currentPath != null && File(currentPath).existsSync();

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          children: [
            // Верхняя шапка документа
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                color: Color(0xFF1E293B),
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.description_rounded, color: Color(0xFF10B981), size: 20),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Оригинал накладной №${widget.invoiceNumber}',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                widget.supplierName,
                                style: const TextStyle(color: Colors.white70, fontSize: 11),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (fileSizeKb > 0) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF10B981).withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  fileSizeKb > 1024
                                      ? '${(fileSizeKb / 1024).toStringAsFixed(1)} МБ • Оригинал HD'
                                      : '${fileSizeKb.toStringAsFixed(0)} КБ • Оригинал HD',
                                  style: const TextStyle(
                                    color: Color(0xFF10B981),
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Кнопка поворота
                  if (fileExists)
                    IconButton(
                      icon: const Icon(Icons.rotate_right_rounded, color: Color(0xFF38BDF8), size: 22),
                      tooltip: 'Повернуть на 90°',
                      onPressed: () {
                        setState(() {
                          _rotationQuarterTurns = (_rotationQuarterTurns + 1) % 4;
                        });
                      },
                    ),
                  // Кнопка закрытия
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white70),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),

            // Область просмотра самого документа с зумом
            Expanded(
              child: !hasPhotos || !fileExists
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.broken_image_outlined, color: Colors.white38, size: 64),
                          const SizedBox(height: 12),
                          const Text(
                            'Файл документа отсутствует или был перемещен',
                            style: TextStyle(color: Colors.white54, fontSize: 13),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            currentPath ?? 'Путь не указан',
                            style: const TextStyle(color: Colors.white24, fontSize: 10),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    )
                  : ClipRRect(
                      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
                      child: InteractiveViewer(
                        transformationController: _transCtrl,
                        minScale: 0.5,
                        maxScale: 6.0,
                        child: Center(
                          child: RotatedBox(
                            quarterTurns: _rotationQuarterTurns,
                            child: Image.file(
                              File(currentPath),
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high,
                              errorBuilder: (_, __, ___) => const Center(
                                child: Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),

            // Нижняя панель (если несколько страниц или подсказка)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: const BoxDecoration(
                color: Color(0xFF1E293B),
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (validPaths.length > 1) ...[
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white70, size: 16),
                      onPressed: _currentPage > 0
                          ? () => setState(() {
                                _currentPage--;
                                _rotationQuarterTurns = 0;
                                _transCtrl.value = Matrix4.identity();
                              })
                          : null,
                    ),
                    Text(
                      'Страница ${_currentPage + 1} из ${validPaths.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    IconButton(
                      icon: const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white70, size: 16),
                      onPressed: _currentPage < validPaths.length - 1
                          ? () => setState(() {
                                _currentPage++;
                                _rotationQuarterTurns = 0;
                                _transCtrl.value = Matrix4.identity();
                              })
                          : null,
                    ),
                  ] else ...[
                    const Row(
                      children: [
                        Icon(Icons.pinch_rounded, color: Colors.white38, size: 16),
                        SizedBox(width: 6),
                        Text(
                          'Масштабируйте двумя пальцами (зум)',
                          style: TextStyle(color: Colors.white38, fontSize: 11),
                        ),
                      ],
                    ),
                  ],
                  TextButton.icon(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    icon: const Icon(Icons.fullscreen_exit_rounded, color: Color(0xFF10B981), size: 16),
                    label: const Text('Закрыть', style: TextStyle(color: Color(0xFF10B981), fontSize: 12)),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
