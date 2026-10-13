import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Утилита для обработки фотографий товаров:
/// 1. Приведение к квадратному формату 1:1 (центр-кроп)
/// 2. Коррекция EXIF-ориентации снимков с камеры
/// 3. Физический поворот фото
/// 4. Быстрое сжатие до оптимального размера без потери качества для сервера gusar.tj
class ImageUtils {
  /// Обрезает фото до строгого квадрата 1:1 по центру, применяет ориентацию и сжимает
  static Future<File> cropToSquareAndCompress(
    File sourceFile,
    String targetPath, {
    int maxSize = 1000,
    int quality = 85,
    int quarterTurns = 0,
  }) async {
    try {
      final bytes = await sourceFile.readAsBytes();
      img.Image? image = img.decodeImage(bytes);
      if (image == null) {
        return await sourceFile.copy(targetPath);
      }

      // 1. Нормализуем ориентацию сенсора камеры (EXIF)
      image = img.bakeOrientation(image);

      // 2. Если пользователь повернул фото вручную (на 90, 180, 270 град)
      final normalizedTurns = quarterTurns % 4;
      if (normalizedTurns != 0) {
        image = img.copyRotate(image, angle: normalizedTurns * 90);
      }

      // 3. Вырезаем строго квадрат 1:1 по центру
      final side = min(image.width, image.height);
      final cropX = (image.width - side) ~/ 2;
      final cropY = (image.height - side) ~/ 2;

      var squareImage = img.copyCrop(
        image,
        x: cropX,
        y: cropY,
        width: side,
        height: side,
      );

      // 4. Масштабируем до разумного максимума (по умолчанию 1000x1000 пикселей)
      if (side > maxSize) {
        squareImage = img.copyResize(
          squareImage,
          width: maxSize,
          height: maxSize,
          interpolation: img.Interpolation.linear,
        );
      }

      // 5. Кодируем в оптимизированный JPEG
      final Uint8List jpgBytes = Uint8List.fromList(img.encodeJpg(squareImage, quality: quality));

      final targetFile = File(targetPath);
      await targetFile.writeAsBytes(jpgBytes);
      return targetFile;
    } catch (e) {
      // При любой непредвиденной ошибке обработки отдаем копию файла
      return await sourceFile.copy(targetPath);
    }
  }
}
