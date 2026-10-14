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

  /// Сжимает изображение до строго заданного максимального размера в килобайтах (по умолчанию 40 КБ)
  /// с сохранением отличной детализации и чёткости этикетки/товара.
  static Uint8List compressImageToMaxKb(
    img.Image sourceImage, {
    int maxKb = 40,
    int initialQuality = 80,
  }) {
    final maxBytes = maxKb * 1024;
    var currentImg = sourceImage;
    int currentQuality = initialQuality;

    // Шаг 1: если изображение слишком большое по разрешению (> 600x600),
    // уменьшаем его до 550x550, что даёт высокую чёткость и минимальный вес
    if (currentImg.width > 600 || currentImg.height > 600) {
      final targetSide = min(currentImg.width, 550);
      currentImg = img.copyResize(
        currentImg,
        width: targetSide,
        height: targetSide,
        interpolation: img.Interpolation.linear,
      );
    }

    Uint8List jpgBytes = Uint8List.fromList(img.encodeJpg(currentImg, quality: currentQuality));
    if (jpgBytes.length <= maxBytes) {
      return jpgBytes;
    }

    // Шаг 2: постепенная регулировка качества JPEG
    final qualitySteps = [74, 66, 58, 50, 42, 35];
    for (final q in qualitySteps) {
      currentQuality = q;
      jpgBytes = Uint8List.fromList(img.encodeJpg(currentImg, quality: currentQuality));
      if (jpgBytes.length <= maxBytes) {
        return jpgBytes;
      }
    }

    // Шаг 3: если всё ещё больше 40 КБ (сложные текстуры), масштабируем разрешение:
    final resizeSteps = [450, 380, 320, 260];
    for (final side in resizeSteps) {
      if (currentImg.width > side) {
        currentImg = img.copyResize(
          currentImg,
          width: side,
          height: side,
          interpolation: img.Interpolation.linear,
        );
      }
      for (final q in [65, 52, 40, 30]) {
        jpgBytes = Uint8List.fromList(img.encodeJpg(currentImg, quality: q));
        if (jpgBytes.length <= maxBytes) {
          return jpgBytes;
        }
      }
    }

    return jpgBytes;
  }

  /// Обрезает фото до строгого квадрата 1:1 по центру, применяет ориентацию и сжимает строго до maxKb (по умолчанию 40 КБ)
  static Future<File> cropToSquareAndCompress(
    File sourceFile,
    String targetPath, {
    int maxSize = 600,
    int quality = 80,
    int quarterTurns = 0,
    int maxKb = 40,
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

      // 4. Масштабируем до разумного максимума (по умолчанию 550x550)
      if (side > maxSize) {
        squareImage = img.copyResize(
          squareImage,
          width: maxSize,
          height: maxSize,
          interpolation: img.Interpolation.linear,
        );
      }

      // 5. Кодируем строго до лимита maxKb (по умолчанию 40 КБ)
      final Uint8List jpgBytes = compressImageToMaxKb(
        squareImage,
        maxKb: maxKb,
        initialQuality: quality,
      );

      final targetFile = File(targetPath);
      await targetFile.writeAsBytes(jpgBytes);
      return targetFile;
    } catch (e) {
      // При любой ошибке отдаем копию файла
      return await sourceFile.copy(targetPath);
    }
  }

  /// Утилита для сжатия любого файла изображения строго до maxKb (по умолчанию 40 КБ)
  static Future<File> compressFileToMaxKb(
    File sourceFile, {
    String? targetPath,
    int maxKb = 40,
  }) async {
    try {
      final bytes = await sourceFile.readAsBytes();
      if (bytes.length <= maxKb * 1024) {
        if (targetPath != null && targetPath != sourceFile.path) {
          return await sourceFile.copy(targetPath);
        }
        return sourceFile;
      }

      img.Image? image = img.decodeImage(bytes);
      if (image == null) return sourceFile;

      image = img.bakeOrientation(image);
      final compressedBytes = compressImageToMaxKb(image, maxKb: maxKb);

      final outPath = targetPath ?? sourceFile.path;
      final outFile = File(outPath);
      await outFile.writeAsBytes(compressedBytes);
      return outFile;
    } catch (e) {
      print('compressFileToMaxKb error: $e');
      return sourceFile;
    }
  }
}
