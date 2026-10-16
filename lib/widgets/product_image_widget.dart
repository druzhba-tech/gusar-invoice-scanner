import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';

class ProductImageWidget extends StatelessWidget {
  final String? imageUrl;
  final String? localImagePath;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget? placeholder;
  final Widget? errorWidget;

  const ProductImageWidget({
    super.key,
    this.imageUrl,
    this.localImagePath,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.placeholder,
    this.errorWidget,
  });

  @override
  Widget build(BuildContext context) {
    // 1. Проверяем локальный файл на устройстве
    if (localImagePath != null && localImagePath!.trim().isNotEmpty) {
      final file = File(localImagePath!.trim());
      if (file.existsSync()) {
        return Image.file(
          file,
          fit: fit,
          width: width,
          height: height,
          errorBuilder: (_, __, ___) => _buildNetworkOrBase64(),
        );
      }
    }

    return _buildNetworkOrBase64();
  }

  Widget _buildNetworkOrBase64() {
    if (imageUrl == null || imageUrl!.trim().isEmpty || imageUrl!.trim() == 'null') {
      return _buildPlaceholder();
    }

    final clean = imageUrl!.trim();

    // 2. Проверяем Base64 (data:image/... или чистый Base64)
    if (clean.startsWith('data:image') || clean.startsWith('/9j/') || (clean.length > 100 && !clean.startsWith('http'))) {
      try {
        String base64Content = clean;
        if (base64Content.contains(',')) {
          base64Content = base64Content.split(',').last;
        }
        final bytes = base64Decode(base64Content.replaceAll(RegExp(r'\s+'), ''));
        return Image.memory(
          bytes,
          fit: fit,
          width: width,
          height: height,
          errorBuilder: (_, __, ___) => _buildError(),
        );
      } catch (_) {
        // Если декодирование base64 не удалось, пробуем обработать как URL
      }
    }

    // 3. Формируем сетевой URL
    String finalUrl = clean;
    if (finalUrl.startsWith('/')) {
      finalUrl = 'https://gusar.tj$finalUrl';
    } else if (finalUrl.startsWith('uploads/') || finalUrl.startsWith('images/')) {
      finalUrl = 'https://gusar.tj/$finalUrl';
    }

    if (finalUrl.startsWith('http://') || finalUrl.startsWith('https://')) {
      return Image.network(
        finalUrl,
        fit: fit,
        width: width,
        height: height,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: const Color(0xFF10B981).withOpacity(0.5),
                value: loadingProgress.expectedTotalBytes != null
                    ? loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes!
                    : null,
              ),
            ),
          );
        },
        errorBuilder: (_, __, ___) => _buildError(),
      );
    }

    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return placeholder ??
        Container(
          width: width,
          height: height,
          color: const Color(0xFF0F172A),
          child: const Center(
            child: Icon(Icons.inventory_2_outlined, color: Colors.white24, size: 22),
          ),
        );
  }

  Widget _buildError() {
    return errorWidget ??
        Container(
          width: width,
          height: height,
          color: const Color(0xFF0F172A),
          child: const Center(
            child: Icon(Icons.broken_image_outlined, color: Colors.white24, size: 20),
          ),
        );
  }
}
