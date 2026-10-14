import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;

/// Утилита для обработки фотографий товаров и документов:
/// 1. Приведение к квадратному формату 1:1 (центр-кроп) для товаров
/// 2. Коррекция EXIF-ориентации снимков с камеры
/// 3. Физический поворот фото на 90°
/// 4. Авто-выравнивание (auto-orientation/deskew) накладных перед чтением нейросетью
/// 5. Быстрое сжатие до оптимального размера без потери качества
class ImageUtils {
  /// Физический поворот файла изображения на 90 градусов по часовой стрелке
  static Future<File> rotateImage90Degrees(File sourceFile, {String? targetPath}) async {
    try {
      final outPath = targetPath ?? sourceFile.path;
      final bytes = await sourceFile.readAsBytes();
      img.Image? image = img.decodeImage(bytes);
      if (image == null) return sourceFile;

      image = img.bakeOrientation(image);
      final rotated = img.copyRotate(image, angle: 90);
      final jpgBytes = Uint8List.fromList(img.encodeJpg(rotated, quality: 92));
      final outFile = File(outPath);
      await outFile.writeAsBytes(jpgBytes);
      return outFile;
    } catch (e) {
      print('rotateImage90Degrees error: $e');
      return sourceFile;
    }
  }

  /// Автоматическое выравнивание листа накладной:
  /// 1. Применяет ориентацию сенсора камеры EXIF (bakeOrientation)
  /// 2. Анализирует угол наклона строк текста через ML Kit (0°, 90°, 180°, 270°)
  /// 3. Поворачивает документ в строго правильное вертикальное/горизонтальное положение перед подачей в нейросеть
  static Future<File> autoStraightenInvoiceImage(File sourceFile, {TextRecognizer? recognizer}) async {
    try {
      final bytes = await sourceFile.readAsBytes();
      img.Image? image = img.decodeImage(bytes);
      if (image == null) return sourceFile;

      // 1. Нормализуем EXIF-ориентацию камеры
      image = img.bakeOrientation(image);

      int rotateAngle = 0;

      // 2. Если доступен распознаватель текста для анализа угла
      if (recognizer != null) {
        try {
          final inputImage = InputImage.fromFile(sourceFile);
          final recognizedText = await recognizer.processImage(inputImage);

          int verticalLines = 0;
          int horizontalLines = 0;
          double totalAngle = 0;
          int angleCount = 0;

          for (final block in recognizedText.blocks) {
            for (final line in block.lines) {
              final box = line.boundingBox;
              if (box.width > box.height * 1.3) {
                horizontalLines++;
              } else if (box.height > box.width * 1.3) {
                verticalLines++;
              }

              if (line.angle != null) {
                totalAngle += line.angle!;
                angleCount++;
              }
            }
          }

          if (angleCount > 0) {
            final avgAngle = (totalAngle / angleCount) % 360;
            if (avgAngle >= 45 && avgAngle < 135) {
              rotateAngle = 270;
            } else if (avgAngle >= 135 && avgAngle < 225) {
              rotateAngle = 180;
            } else if (avgAngle >= 225 && avgAngle < 315) {
              rotateAngle = 90;
            }
          } else if (verticalLines > horizontalLines * 1.5 && verticalLines >= 4) {
            // Строки расположены вертикально (снимок сделан боком) -> поворачиваем на 90°
            rotateAngle = 90;
          }
        } catch (_) {}
      }

      if (rotateAngle != 0) {
        image = img.copyRotate(image, angle: rotateAngle);
      }

      final jpgBytes = Uint8List.fromList(img.encodeJpg(image, quality: 92));
      await sourceFile.writeAsBytes(jpgBytes);
      return sourceFile;
    } catch (e) {
      print('autoStraightenInvoiceImage error: $e');
      return sourceFile;
    }
  }

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
