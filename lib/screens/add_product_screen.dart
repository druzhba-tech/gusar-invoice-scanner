import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../models/product.dart';
import '../services/api_service.dart';
import '../utils/image_utils.dart';
import '../widgets/barcode_scanner_dialog.dart';

class AddProductScreen extends StatefulWidget {
  final String? initialName;
  final double? initialCostPrice;
  final double? initialRetailPrice;
  final double? initialWholesalePrice;
  final String? initialBarcode;
  final ProductType? initialType;

  const AddProductScreen({
    super.key,
    this.initialName,
    this.initialCostPrice,
    this.initialRetailPrice,
    this.initialWholesalePrice,
    this.initialBarcode,
    this.initialType,
  });

  @override
  State<AddProductScreen> createState() => _AddProductScreenState();
}

class _AddProductScreenState extends State<AddProductScreen> {
  final ApiService _api = ApiService();
  final ImagePicker _picker = ImagePicker();
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _nameCtrl;
  late TextEditingController _barcodeCtrl;
  late TextEditingController _pluCtrl;
  late TextEditingController _costPriceCtrl;
  late TextEditingController _retailPriceCtrl;
  late TextEditingController _wholesalePriceCtrl;
  late TextEditingController _categoryCtrl;

  ProductType _selectedType = ProductType.barcode;
  String _selectedUnit = 'шт';
  File? _imageFile;
  int _imageRotationTurns = 0; // 0, 1, 2, 3 (для поворота на 90 градусов)
  bool _isSaving = false;

  final List<String> _commonUnits = ['шт', 'кг', 'л', 'уп', 'пач', 'кор', 'бутыл'];

  @override
  void initState() {
    super.initState();
    _selectedType = widget.initialType ?? ProductType.barcode;
    _nameCtrl = TextEditingController(text: widget.initialName ?? '');
    _barcodeCtrl = TextEditingController(text: widget.initialBarcode ?? '');
    _pluCtrl = TextEditingController();
    _costPriceCtrl = TextEditingController(
      text: widget.initialCostPrice != null && widget.initialCostPrice! > 0
          ? widget.initialCostPrice!.toStringAsFixed(2)
          : '',
    );
    _retailPriceCtrl = TextEditingController(
      text: widget.initialRetailPrice != null && widget.initialRetailPrice! > 0
          ? widget.initialRetailPrice!.toStringAsFixed(2)
          : '',
    );
    _wholesalePriceCtrl = TextEditingController(
      text: widget.initialWholesalePrice != null && widget.initialWholesalePrice! > 0
          ? widget.initialWholesalePrice!.toStringAsFixed(2)
          : '',
    );
    _categoryCtrl = TextEditingController(text: 'Общая');

    if (_selectedType == ProductType.weight) {
      _selectedUnit = 'кг';
      final nextPlu = _calculateNextPlu();
      _pluCtrl.text = nextPlu;
      _barcodeCtrl.text = '20${int.parse(nextPlu).toString().padLeft(5, '0')}00000';
    } else if (_selectedType == ProductType.internal) {
      if (_barcodeCtrl.text.isEmpty) {
        _barcodeCtrl.text = _calculateNextInternalCode();
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _barcodeCtrl.dispose();
    _pluCtrl.dispose();
    _costPriceCtrl.dispose();
    _retailPriceCtrl.dispose();
    _wholesalePriceCtrl.dispose();
    _categoryCtrl.dispose();
    super.dispose();
  }

  // Расчёт процента наценки
  String? get _markupPercentage {
    final cost = double.tryParse(_costPriceCtrl.text.replaceAll(',', '.')) ?? 0;
    final retail = double.tryParse(_retailPriceCtrl.text.replaceAll(',', '.')) ?? 0;
    if (cost <= 0 || retail <= 0) return null;
    final markup = ((retail - cost) / cost) * 100;
    return '${markup >= 0 ? '+' : ''}${markup.toStringAsFixed(1)}%';
  }

  // Сканирование штрихкода через камеру
  Future<void> _scanBarcode() async {
    final scanned = await BarcodeScannerDialog.scan(context);
    if (scanned != null && scanned.isNotEmpty) {
      setState(() {
        _barcodeCtrl.text = scanned;
      });
      _checkDuplicateBarcode(scanned);
    }
  }

  // Проверка на дубликат штрихкода
  void _checkDuplicateBarcode(String barcode) {
    for (var p in _api.cachedProducts) {
      if (p.barcode != null && p.barcode!.trim() == barcode.trim()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.orange.shade800,
            content: Row(
              children: [
                const Icon(Icons.info_outline, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Товар с таким штрихкодом уже есть в базе:\n"${p.name}"'),
                ),
              ],
            ),
          ),
        );
        break;
      }
    }
  }

  // Автоматический расчёт следующего 6-значного внутреннего кода в последовательности
  String _calculateNextInternalCode() {
    int maxCode = 100000;
    for (var p in _api.cachedProducts) {
      final code = p.barcode ?? '';
      if (RegExp(r'^\d{6}$').hasMatch(code)) {
        final val = int.tryParse(code);
        if (val != null && val >= 100000 && val < 999999) {
          if (val > maxCode) maxCode = val;
        }
      }
    }
    return (maxCode + 1).toString().padLeft(6, '0');
  }

  // Генерация следующего 6-значного внутреннего кода
  void _generateInternalCode() {
    final next = _calculateNextInternalCode();
    setState(() {
      _barcodeCtrl.text = next;
    });
  }

  // Генерация EAN-13 штрихкода
  void _generateEan13() {
    final randomDigits = List.generate(11, (_) => Random().nextInt(10)).join();
    final body = '29$randomDigits'; // префикс внутренней фасовки магазина
    // Расчёт контрольной суммы EAN-13
    int sum = 0;
    for (int i = 0; i < 12; i++) {
      int d = int.parse(body[i]);
      sum += (i % 2 == 0) ? d : d * 3;
    }
    int checkDigit = (10 - (sum % 10)) % 10;
    final fullEan = '$body$checkDigit';

    setState(() {
      _barcodeCtrl.text = fullEan;
    });
  }

  // Автоматический расчёт следующего номера PLU для весов (начиная от 1)
  String _calculateNextPlu() {
    int maxPlu = 0;
    for (var p in _api.cachedProducts) {
      if (p.pluCode != null && p.pluCode!.isNotEmpty) {
        final parsed = int.tryParse(p.pluCode!);
        if (parsed != null && parsed > maxPlu) maxPlu = parsed;
      } else if (p.productType == ProductType.weight && p.barcode != null && p.barcode!.startsWith('20') && p.barcode!.length == 13) {
        final pluPart = int.tryParse(p.barcode!.substring(2, 7));
        if (pluPart != null && pluPart > maxPlu) maxPlu = pluPart;
      }
    }
    return (maxPlu + 1).toString(); // Последовательность начинается строго от 1
  }

  // Генерация следующего номера для весов
  void _generateNextPlu() {
    final nextPlu = _calculateNextPlu();
    setState(() {
      _pluCtrl.text = nextPlu;
      _barcodeCtrl.text = '20${int.parse(nextPlu).toString().padLeft(5, '0')}00000';
    });
  }

  // Выбор фото (камера или галерея) с обрезкой до 1:1 (квадрат)
  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 92,
      );

      if (picked != null) {
        // Сохраняем во внутреннее хранилище приложения в строгом формате 1:1
        final appDir = await getApplicationDocumentsDirectory();
        final fileName = 'prod_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final targetPath = '${appDir.path}/$fileName';

        final savedImage = await ImageUtils.cropToSquareAndCompress(
          File(picked.path),
          targetPath,
          maxSize: 550,
          quality: 80,
          maxKb: 40,
        );

        setState(() {
          _imageFile = savedImage;
          _imageRotationTurns = 0;
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка при загрузке фото: $e'), backgroundColor: Colors.redAccent),
      );
    }
  }

  void _showImageSourcePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Фотография товара',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFF10B981),
                  child: Icon(Icons.camera_alt_rounded, color: Colors.white),
                ),
                title: const Text('Сделать снимок на камеру', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFF3B82F6),
                  child: Icon(Icons.photo_library_rounded, color: Colors.white),
                ),
                title: const Text('Выбрать из галереи', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.gallery);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _rotateImage() {
    setState(() {
      _imageRotationTurns = (_imageRotationTurns + 1) % 4;
    });
    HapticFeedback.selectionClick();
  }

  void _removeImage() {
    setState(() {
      _imageFile = null;
      _imageRotationTurns = 0;
    });
  }

  void _viewFullScreenImage() {
    if (_imageFile == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            title: Text(_nameCtrl.text.isNotEmpty ? _nameCtrl.text : 'Фото товара', style: const TextStyle(color: Colors.white)),
            leading: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          body: Center(
            child: InteractiveViewer(
              child: RotatedBox(
                quarterTurns: _imageRotationTurns,
                child: Image.file(_imageFile!),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Сохранение нового товара
  Future<void> _saveProduct() async {
    if (!_formKey.currentState!.validate()) return;

    final name = _nameCtrl.text.trim();
    final costPrice = double.tryParse(_costPriceCtrl.text.replaceAll(',', '.')) ?? 0.0;
    final retailPrice = double.tryParse(_retailPriceCtrl.text.replaceAll(',', '.')) ?? 0.0;
    final wholesalePrice = double.tryParse(_wholesalePriceCtrl.text.replaceAll(',', '.'));

    String finalBarcode = _barcodeCtrl.text.trim();
    if (_selectedType == ProductType.weight) {
      final plu = _pluCtrl.text.trim();
      final pluNum = int.tryParse(plu) ?? int.parse(_calculateNextPlu());
      finalBarcode = '20${pluNum.toString().padLeft(5, '0')}00000';
    } else if (_selectedType == ProductType.internal) {
      if (finalBarcode.isEmpty || !RegExp(r'^\d{6}$').hasMatch(finalBarcode)) {
        finalBarcode = _calculateNextInternalCode();
      }
    }

    setState(() => _isSaving = true);

    try {
      File? imageToSave = _imageFile;
      if (imageToSave != null && _imageRotationTurns != 0) {
        final appDir = await getApplicationDocumentsDirectory();
        final rotName = 'rot_prod_${DateTime.now().millisecondsSinceEpoch}.jpg';
        imageToSave = await ImageUtils.cropToSquareAndCompress(
          imageToSave,
          '${appDir.path}/$rotName',
          quarterTurns: _imageRotationTurns,
          maxSize: 550,
          quality: 80,
          maxKb: 40,
        );
      }

      final created = await _api.createProduct(
        name: name,
        barcode: finalBarcode,
        price: retailPrice,
        wholesalePrice: wholesalePrice,
        costPrice: costPrice,
        category: _categoryCtrl.text.trim(),
        productType: _selectedType,
        unit: _selectedUnit,
        pluCode: _pluCtrl.text.trim().isNotEmpty ? _pluCtrl.text.trim() : null,
        localImagePath: imageToSave?.path,
      );

      setState(() => _isSaving = false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF10B981),
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(child: Text('Товар "$name" успешно добавлен в базу!')),
              ],
            ),
          ),
        );
        Navigator.pop(context, created);
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка сохранения товара: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A), // Slate 900
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        title: const Text(
          'Добавление нового товара',
          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          children: [
            // Склад привязки
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.store_rounded, color: Color(0xFF10B981), size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Склад привязки товара:', style: TextStyle(color: Colors.white54, fontSize: 11)),
                        Text(_api.currentStoreName, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // 1. Выбор типа товара
            const Text(
              'Тип товара',
              style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _buildTypeCard(
                    type: ProductType.barcode,
                    icon: Icons.qr_code_2_rounded,
                    title: 'Штрихкод',
                    subtitle: 'Штучный товар',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildTypeCard(
                    type: ProductType.internal,
                    icon: Icons.tag_rounded,
                    title: 'Внутренний',
                    subtitle: 'Без штрихкода',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildTypeCard(
                    type: ProductType.weight,
                    icon: Icons.scale_rounded,
                    title: 'Весы',
                    subtitle: 'Весовой (кг)',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // 2. Фотография товара с возможностью редактирования
            _buildPhotoSection(),
            const SizedBox(height: 20),

            // 3. Название товара
            const Text(
              'Название товара *',
              style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            TextFormField(
              controller: _nameCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              decoration: InputDecoration(
                hintText: 'Например: Вода Сиёма 0.5л с газом',
                hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                filled: true,
                fillColor: const Color(0xFF1E293B),
                prefixIcon: const Icon(Icons.shopping_bag_outlined, color: Color(0xFF10B981), size: 20),
                suffixIcon: _nameCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: Colors.white54, size: 18),
                        onPressed: () => setState(() => _nameCtrl.clear()),
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
              validator: (val) {
                if (val == null || val.trim().isEmpty) return 'Введите наименование товара';
                if (val.trim().length < 2) return 'Название слишком короткое';
                return null;
              },
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 20),

            // 4. Идентификация (Штрихкод / Внутренний код / Весы)
            _buildIdentificationSection(),
            const SizedBox(height: 20),

            // 5. Цены (Себестоимость и Розница)
            _buildPricingSection(),
            const SizedBox(height: 20),

            // 6. Единица измерения и Категория
            _buildUnitAndCategorySection(),
            const SizedBox(height: 32),

            // 7. Кнопка создания товара
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 4,
              ),
              onPressed: _isSaving ? null : _saveProduct,
              child: _isSaving
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                    )
                  : const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_task_rounded, color: Colors.white, size: 20),
                        SizedBox(width: 8),
                        Text(
                          'Сохранить товар в каталог',
                          style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  // Карточка выбора типа товара
  Widget _buildTypeCard({
    required ProductType type,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final isSelected = _selectedType == type;

    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedType = type;
          if (type == ProductType.weight) {
            _selectedUnit = 'кг';
            if (_pluCtrl.text.isEmpty) _generateNextPlu();
          } else if (type == ProductType.internal) {
            if (_selectedUnit == 'кг') _selectedUnit = 'шт';
            if (_barcodeCtrl.text.isEmpty || !RegExp(r'^\d{6}$').hasMatch(_barcodeCtrl.text)) {
              _generateInternalCode();
            }
          } else if (_selectedUnit == 'кг') {
            _selectedUnit = 'шт';
          }
        });
        HapticFeedback.selectionClick();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF10B981).withOpacity(0.15) : const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? const Color(0xFF10B981) : Colors.white12,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color: isSelected ? const Color(0xFF10B981) : Colors.white60,
              size: 26,
            ),
            const SizedBox(height: 6),
            Text(
              title,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(
                color: isSelected ? const Color(0xFF34D399) : Colors.white38,
                fontSize: 9,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // Секция фото с возможностями редактирования
  Widget _buildPhotoSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Фотография товара',
              style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
            ),
            if (_imageFile != null)
              TextButton.icon(
                onPressed: _showImageSourcePicker,
                icon: const Icon(Icons.refresh_rounded, color: Color(0xFF10B981), size: 16),
                label: const Text('Заменить', style: TextStyle(color: Color(0xFF10B981), fontSize: 12)),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (_imageFile == null)
          GestureDetector(
            onTap: _showImageSourcePicker,
            child: Container(
              height: 120,
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white12, style: BorderStyle.solid),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircleAvatar(
                    backgroundColor: Color(0xFF0F172A),
                    radius: 24,
                    child: Icon(Icons.add_a_photo_rounded, color: Color(0xFF10B981), size: 22),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Добавить фото товара',
                    style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Сделайте снимок на камеру или выберите из галереи',
                    style: TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF10B981).withOpacity(0.5)),
            ),
            child: Column(
              children: [
                // Превью фото
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(13)),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      GestureDetector(
                        onTap: _viewFullScreenImage,
                        child: Container(
                          height: 180,
                          width: double.infinity,
                          color: Colors.black,
                          child: RotatedBox(
                            quarterTurns: _imageRotationTurns,
                            child: Image.file(_imageFile!, fit: BoxFit.contain),
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.7),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.zoom_in_rounded, color: Colors.white70, size: 14),
                              SizedBox(width: 4),
                              Text('Нажмите для зума', style: TextStyle(color: Colors.white70, fontSize: 10)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Панель инструментов редактирования фото
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      TextButton.icon(
                        onPressed: _rotateImage,
                        icon: const Icon(Icons.rotate_right_rounded, color: Colors.white70, size: 18),
                        label: const Text('Повернуть', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      ),
                      Container(height: 20, width: 1, color: Colors.white12),
                      TextButton.icon(
                        onPressed: _showImageSourcePicker,
                        icon: const Icon(Icons.camera_alt_outlined, color: Colors.white70, size: 18),
                        label: const Text('Переснять', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      ),
                      Container(height: 20, width: 1, color: Colors.white12),
                      TextButton.icon(
                        onPressed: _removeImage,
                        icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 18),
                        label: const Text('Удалить', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // Секция идентификации в зависимости от выбранного типа
  Widget _buildIdentificationSection() {
    switch (_selectedType) {
      case ProductType.barcode:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Штрихкод товара *',
                  style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                ),
                TextButton.icon(
                  onPressed: _generateEan13,
                  icon: const Icon(Icons.auto_awesome, color: Color(0xFF34D399), size: 14),
                  label: const Text('Сгенерировать EAN', style: TextStyle(color: Color(0xFF34D399), fontSize: 11)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _barcodeCtrl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      hintText: '4820000112233...',
                      hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      prefixIcon: const Icon(Icons.qr_code_rounded, color: Color(0xFF10B981), size: 20),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                    validator: (val) {
                      if (_selectedType == ProductType.barcode && (val == null || val.trim().isEmpty)) {
                        return 'Введите или отсканируйте штрихкод';
                      }
                      return null;
                    },
                    onChanged: (val) {
                      if (val.length >= 8) _checkDuplicateBarcode(val);
                    },
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _scanBarcode,
                  icon: const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 18),
                  label: const Text('Скан', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ],
        );

      case ProductType.internal:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Внутренний код (6 цифр) *',
                  style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                ),
                TextButton.icon(
                  onPressed: _generateInternalCode,
                  icon: const Icon(Icons.auto_awesome, color: Color(0xFF34D399), size: 14),
                  label: const Text('Следующий код', style: TextStyle(color: Color(0xFF34D399), fontSize: 11)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextFormField(
              controller: _barcodeCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              style: const TextStyle(color: Colors.white, fontSize: 16, fontFamily: 'monospace', fontWeight: FontWeight.bold, letterSpacing: 2.0),
              decoration: InputDecoration(
                hintText: '100001',
                hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
                helperText: 'Ровно 6 цифр (система определяет следующий код автоматически)',
                helperStyle: const TextStyle(color: Color(0xFF34D399), fontSize: 11),
                filled: true,
                fillColor: const Color(0xFF1E293B),
                prefixIcon: const Icon(Icons.tag_rounded, color: Color(0xFF10B981), size: 20),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
              validator: (val) {
                if (_selectedType == ProductType.internal) {
                  if (val == null || val.trim().isEmpty) return 'Введите 6-значный внутренний код';
                  if (!RegExp(r'^\d{6}$').hasMatch(val.trim())) return 'Внутренний код должен состоять ровно из 6 цифр';
                }
                return null;
              },
            ),
          ],
        );

      case ProductType.weight:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Код товара на весах (PLU) *',
                  style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                ),
                TextButton.icon(
                  onPressed: _generateNextPlu,
                  icon: const Icon(Icons.auto_awesome, color: Color(0xFF34D399), size: 14),
                  label: const Text('Следующий PLU', style: TextStyle(color: Color(0xFF34D399), fontSize: 11)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextFormField(
                    controller: _pluCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(5),
                    ],
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    decoration: InputDecoration(
                      hintText: '1, 2, 3...',
                      hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                      helperText: 'Начиная от 1',
                      helperStyle: const TextStyle(color: Color(0xFF34D399), fontSize: 11),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      prefixIcon: const Icon(Icons.scale_rounded, color: Color(0xFF10B981), size: 20),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                    validator: (val) {
                      if (_selectedType == ProductType.weight) {
                        if (val == null || val.trim().isEmpty) return 'Укажите номер PLU';
                        final num = int.tryParse(val.trim());
                        if (num == null || num < 1) return 'PLU должен быть от 1 и выше';
                      }
                      return null;
                    },
                    onChanged: (val) {
                      final parsed = int.tryParse(val.trim());
                      if (parsed != null && parsed >= 1) {
                        setState(() {
                          _barcodeCtrl.text = '20${parsed.toString().padLeft(5, '0')}00000';
                        });
                      }
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 3,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Формат штрихкода весов:', style: TextStyle(color: Colors.white54, fontSize: 10)),
                        Text(
                          _barcodeCtrl.text.isNotEmpty ? '${_barcodeCtrl.text.substring(0, min(7, _barcodeCtrl.text.length))}WWWWWC' : '20XXXXXWWWWWC',
                          style: const TextStyle(color: Color(0xFF34D399), fontSize: 12, fontFamily: 'monospace', fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
    }
  }

  // Секция цен
  Widget _buildPricingSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Цены и наценка',
              style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
            ),
            if (_markupPercentage != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Наценка: $_markupPercentage',
                  style: const TextStyle(color: Color(0xFF10B981), fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            // Закупка (себестоимость)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Закупка (себестоимость)', style: TextStyle(color: Colors.white54, fontSize: 11)),
                  const SizedBox(height: 4),
                  TextFormField(
                    controller: _costPriceCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                    decoration: InputDecoration(
                      hintText: '0.00',
                      hintStyle: const TextStyle(color: Colors.white38),
                      suffixText: 'TJS',
                      suffixStyle: const TextStyle(color: Colors.white54, fontSize: 12),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Оптовая цена
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Оптовая цена', style: TextStyle(color: Colors.white54, fontSize: 11)),
                  const SizedBox(height: 4),
                  TextFormField(
                    controller: _wholesalePriceCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 15, fontWeight: FontWeight.w600),
                    decoration: InputDecoration(
                      hintText: '0.00',
                      hintStyle: const TextStyle(color: Colors.white38),
                      suffixText: 'TJS',
                      suffixStyle: const TextStyle(color: Color(0xFF38BDF8), fontSize: 12),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Розничная цена (продажа)
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Розничная цена (продажа) *', style: TextStyle(color: Colors.white54, fontSize: 11)),
            const SizedBox(height: 4),
            TextFormField(
              controller: _retailPriceCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: Color(0xFF10B981), fontSize: 16, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                hintText: '0.00',
                hintStyle: const TextStyle(color: Colors.white38),
                suffixText: 'TJS',
                suffixStyle: const TextStyle(color: Color(0xFF10B981), fontSize: 13, fontWeight: FontWeight.bold),
                filled: true,
                fillColor: const Color(0xFF1E293B),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
              validator: (val) {
                final price = double.tryParse((val ?? '').replaceAll(',', '.')) ?? 0;
                if (price <= 0) return 'Укажите розничную цену';
                return null;
              },
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ],
    );
  }

  // Единица измерения и категория
  Widget _buildUnitAndCategorySection() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Единица измерения
        Expanded(
          flex: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Единица изм.', style: TextStyle(color: Colors.white54, fontSize: 11)),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedUnit,
                    dropdownColor: const Color(0xFF1E293B),
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    icon: const Icon(Icons.arrow_drop_down, color: Colors.white54),
                    isExpanded: true,
                    items: _commonUnits.map((u) {
                      return DropdownMenuItem(value: u, child: Text(u));
                    }).toList(),
                    onChanged: _selectedType == ProductType.weight
                        ? null // Для весового всегда кг
                        : (val) {
                            if (val != null) setState(() => _selectedUnit = val);
                          },
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        // Категория
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Категория товара', style: TextStyle(color: Colors.white54, fontSize: 11)),
              const SizedBox(height: 4),
              TextFormField(
                controller: _categoryCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Общая',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: const Color(0xFF1E293B),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
