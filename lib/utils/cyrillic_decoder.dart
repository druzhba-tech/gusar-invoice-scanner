/// Интеллектуальный декодер латинских псевдо-символов Google ML Kit в правильную кириллицу
/// и очиститель артикулов поставщика.
///
/// Google ML Kit на Android не имеет встроенной модели кириллицы и распознаёт русские буквы
/// через латиницу (TextRecognitionScript.latin):
/// - "Конфеты" -> "KOHoeTbI"
/// - "Крокант" -> "KpoKaHT"
/// - "деревенские" -> "lepeBeHCKVe"
/// - "сливки" -> "cnMBKM"
/// - "со вкусом" -> "CO BKYcoM"
/// - "10 шт" -> "1OuT"
/// - "500 гр" -> "500rp"
///
/// Этот класс восстанавливает человеческий русский язык и очищает строки для идеального сопоставления с базой.
class CyrillicDecoder {
  static final Map<String, String> _wordMap = {
    'kohoetbi': 'Конфеты',
    'kohetbi': 'Конфеты',
    'kohoetbl': 'Конфеты',
    'kohoet': 'Конфеты',
    'konfety': 'Конфеты',
    'kpokaht': 'Крокант',
    'krokaht': 'Крокант',
    'kpokant': 'Крокант',
    'krokant': 'Крокант',
    'крокант': 'Крокант',
    'lepebehckve': 'деревенские',
    'derevenskie': 'деревенские',
    'lepebehckue': 'деревенские',
    'iepebehckue': 'деревенские',
    'lepebehckoe': 'деревенское',
    'iepebehckoe': 'деревенское',
    'iеревенские': 'деревенские',
    'деревенские': 'деревенские',
    'aukmho': 'АКТИВНО',
    'aukvho': 'АКТИВНО',
    'aukmuo': 'АКТИВНО',
    'cbipom': 'сыром',
    'cblpom': 'сыром',
    'cbip': 'сыр',
    'cblp': 'сыр',
    'syr': 'сыр',
    'conblo': 'солью',
    'conbio': 'солью',
    'сопыо': 'солью',
    'conb': 'соль',
    'mahro': 'Манго',
    'mango': 'Манго',
    'mapakyum': 'Маракуйя',
    'маракуйм': 'Маракуйя',
    'marakuya': 'Маракуйя',
    'nepcmka': 'персика',
    'nepcuka': 'персика',
    'персмка': 'персика',
    'batohymk': 'Батончик',
    'batonchik': 'Батончик',
    'cnmbkm': 'сливки',
    'cnubku': 'сливки',
    'slivki': 'сливки',
    'cnmbki': 'сливки',
    'bkycom': 'вкусом',
    'vkusom': 'вкусом',
    'co': 'со',
    'monoko': 'молоко',
    'moloko': 'молоко',
    'macno': 'масло',
    'maslo': 'масло',
    'maclo': 'масло',
    'caxap': 'сахар',
    'saxar': 'сахар',
    'uau': 'чай',
    'chay': 'чай',
    'kooe': 'кофе',
    'kofe': 'кофе',
    'myka': 'мука',
    'muka': 'мука',
    'puc': 'рис',
    'ris': 'рис',
    'boda': 'вода',
    'voda': 'вода',
    'cok': 'сок',
    'sok': 'сок',
    'xneb': 'хлеб',
    'xleb': 'хлеб',
    'nehehbe': 'печенье',
    'nechenbe': 'печенье',
    'pechenye': 'печенье',
    'wokonag': 'шоколад',
    'shokolad': 'шоколад',
    'choko': 'шоколад',
    'baonи': 'вафли',
    'vafli': 'вафли',
    'koneaca': 'колбаса',
    'kolbasa': 'колбаса',
    'cochckи': 'сосиски',
    'sosiski': 'сосиски',
    'cappenkи': 'сардельки',
    'sardelki': 'сардельки',
    'hanuTok': 'напиток',
    'napitok': 'напиток',
    'curapetbl': 'сигареты',
    'sigarety': 'сигареты',
    'cmetana': 'сметана',
    'cmetaha': 'сметана',
    'keonp': 'кефир',
    'tbopor': 'творог',
    'makapohbl': 'макароны',
    'makarony': 'макароны',
    'rpeuka': 'гречка',
    'grechka': 'гречка',
    'mbino': 'мыло',
    'mylo': 'мыло',
    'nopowok': 'порошок',
    'poroshok': 'порошок',
    'nacTa': 'паста',
    'pasta': 'паста',
    'canqetkn': 'салфетки',
    'salfetki': 'салфетки',
    'tyanethas': 'туалетная',
    'bymara': 'бумага',
    'bumaga': 'бумага',
    'деуенье': 'Печенье',
    'деуеньe': 'Печенье',
    'деуен': 'Печенье',
    'аетское': 'Детское',
    'аетскoe': 'Детское',
    'aetckoe': 'Детское',
    'вонаи': 'Бонди',
    'бонаи': 'Бонди',
    'bohau': 'Бонди',
    'vohau': 'Бонди',
    '5ohau': 'Бонди',
    'бонди': 'Бонди',
    'модом': 'йодом',
    'йoдом': 'йодом',
    'капымо': 'кальцием',
    'капым0': 'кальцием',
    'кепеѕ': 'железом',
    'kenes': 'железом',
    'обог': 'обог.',
  };

  /// Декодирование названия товара из накладной
  static String decode(String raw) {
    if (raw.trim().isEmpty) return raw;

    var t = raw.trim();

    // 0. Срезаем лидирующий порядковый номер строки (03, 01, 1, 2, 14)
    t = t.replaceAll(RegExp(r'^[0-9]{1,3}\s+'), '');

    // 1. Срезаем лидирующий артикул поставщика (HK931, PBK475, BR120, АРТ123, 12345678)
    t = t.replaceAll(RegExp(r'^[A-Za-zА-Яа-я]{1,4}\d{2,9}\s+'), '');
    t = t.replaceAll(RegExp(r'^[0-9]{6,14}\s+'), '');

    // 2. Срезаем цифры количества мест в конце строки перед ценой или дублирующийся артикул: " 2", " 1", "(HK931) 2100"
    t = t.replaceAll(RegExp(r'\s+\([A-Za-zА-Яа-я0-9\-_]+\)\s+\d+$'), '');
    t = t.replaceAll(RegExp(r'\s+\d{1,2}$'), '');

    // 3. Нормализация опечаток единиц измерения (1OuT -> 10 шт, 24uT -> 24 шт, 500rp -> 500 гр)
    t = t.replaceAllMapped(RegExp(r'(\d+)[Oo]u[Tt]\b', caseSensitive: false), (m) => '${m[1]}0 шт');
    t = t.replaceAllMapped(RegExp(r'(\d+)\s*[uU][tT]\b'), (m) => '${m[1]} шт');
    t = t.replaceAllMapped(RegExp(r'(\d+)\s*[wW][tT]\.?\b', caseSensitive: false), (m) => '${m[1]} шт');
    t = t.replaceAllMapped(RegExp(r'(\d+)\s*rp\b', caseSensitive: false), (m) => '${m[1]} гр');
    t = t.replaceAllMapped(RegExp(r'(\d+)\s*kr\b', caseSensitive: false), (m) => '${m[1]} кг');
    t = t.replaceAllMapped(RegExp(r'(\d+)\s*k[rg]\b', caseSensitive: false), (m) => '${m[1]} кг');

    // 3.1 Замена латинских связок и префиксов:
    // "Маракуйя n персика" -> "Маракуйя и персика"
    t = t.replaceAllMapped(RegExp(r'([а-яА-ЯёЁa-zA-Z]{2,})\s+[nN]\s+([а-яА-ЯёЁa-zA-Z]{2,})'), (m) => '${m[1]} и ${m[2]}');
    // "Iере..." -> "Дере..."
    t = t.replaceAll(RegExp(r'\b[iI|l]ере', caseSensitive: false), 'дере');
    t = t.replaceAll(RegExp(r'\b[iI|l]еревен', caseSensitive: false), 'деревен');

    // 4. Пословная нормализация
    final words = t.split(RegExp(r'\s+'));
    final List<String> resultWords = [];

    for (var w in words) {
      if (w.isEmpty) continue;

      // Извлекаем префикс (кавычки/скобки), корень и суффикс
      final match = RegExp(r'^([^\w]*)(.*?)([^\w]*)$', unicode: true).firstMatch(w);
      if (match == null) {
        resultWords.add(w);
        continue;
      }

      final prefix = match.group(1) ?? '';
      final core = match.group(2) ?? '';
      final suffix = match.group(3) ?? '';
      final coreLower = core.toLowerCase();

      if (_wordMap.containsKey(coreLower)) {
        var rep = _wordMap[coreLower]!;
        if (core == core.toUpperCase() && core.length > 2) {
          rep = rep.toUpperCase();
        } else if (core.isNotEmpty && core[0] == core[0].toUpperCase() && core[0] != core[0].toLowerCase()) {
          rep = rep[0].toUpperCase() + (rep.length > 1 ? rep.substring(1) : '');
        }
        resultWords.add('$prefix$rep$suffix');
      } else {
        final decodedCore = _decodeHomoglyphs(core);
        resultWords.add('$prefix$decodedCore$suffix');
      }
    }

    return resultWords.join(' ');
  }

  /// Посимвольная нормализация смешанных букв (хомоглифов)
  static String _decodeHomoglyphs(String word) {
    // Известные бренды на латинице не переводим
    const commonEn = {'samsung', 'hp', 'lg', 'pro', 'max', 'mini', 'plus', 'air', 'laserjet', 'usb', 'led'};
    if (commonEn.contains(word.toLowerCase())) {
      return word;
    }

    var w = word;
    // Характерные спайки ML Kit
    w = w.replaceAll('bI', 'ы').replaceAll('bl', 'ы');
    w = w.replaceAll(RegExp(r'([bcdfghjklmnpqrstvwxyz])oe([bcdfghjklmnpqrstvwxyz])', caseSensitive: false), r'${1}ф${2}');
    w = w.replaceAll(RegExp(r'^oe', caseSensitive: false), 'ф');
    w = w.replaceAll(RegExp(r'^le', caseSensitive: false), 'де');
    w = w.replaceAll(RegExp(r'cn', caseSensitive: false), 'сл');
    w = w.replaceAll(RegExp(r'ckve$', caseSensitive: false), 'ские');
    w = w.replaceAll(RegExp(r'ckoe$', caseSensitive: false), 'ское');
    w = w.replaceAll(RegExp(r'ckuй$', caseSensitive: false), 'ский');
    w = w.replaceAll(RegExp(r'mbkm$', caseSensitive: false), 'вки');

    // Если слово содержит признаки кириллицы или явных опечаток, заменяем латинские двойники
    if (w.contains('ы') || RegExp(r'[а-яА-ЯёЁғқӣӯҳҷҒҚӢӮҲҶ]').hasMatch(w)) {
      const latinToCyr = {
        'A': 'А', 'B': 'В', 'E': 'Е', 'K': 'К', 'M': 'М', 'H': 'Н',
        'O': 'О', 'P': 'Р', 'C': 'С', 'T': 'Т', 'Y': 'У', 'X': 'Х',
        'a': 'а', 'e': 'е', 'k': 'к', 'm': 'м', 'o': 'о', 'p': 'р',
        'c': 'с', 't': 'т', 'y': 'у', 'x': 'х',
      };
      final buffer = StringBuffer();
      for (int i = 0; i < w.length; i++) {
        final ch = w[i];
        buffer.write(latinToCyr[ch] ?? ch);
      }
      w = buffer.toString();
    }

    return w;
  }
}
