import 'dart:convert';
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';

const uuid = Uuid();
const types = [
  '游览/活动',
  '交通/移动',
  '游览',
  '餐饮',
  '购物',
  '其他',
  '住宿',
  '航班',
  '铁路',
  '市内交通',
  '长途汽车',
  '轮渡',
  '自驾',
  '租车',
  '出租车',
];
const categories = ['交通', '住宿', '餐饮', '门票/活动', '购物', '其他'];
const currencies = [
  'CNY',
  'EUR',
  'USD',
  'GBP',
  'JPY',
  'KRW',
  'HKD',
  'TWD',
  'CHF',
  'NOK',
  'SEK',
  'DKK',
  'ISK',
  'THB',
  'SGD',
  'AUD',
  'CAD',
  'NZD',
  'KWD',
];
int digits(String code) => ['JPY', 'KRW', 'ISK'].contains(code)
    ? 0
    : code == 'KWD'
    ? 3
    : 2;

// Integer arithmetic keeps conversion and rounding deterministic on both devices.
BigInt decimalUnits(String text, int scale) {
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(text) || text.length > 20) {
    throw const FormatException('金额或汇率格式不正确');
  }
  final parts = text.split('.');
  final fraction = parts.length == 2 ? parts[1] : '';
  if (fraction.length > scale) throw FormatException('最多填写 $scale 位小数');
  return BigInt.parse(parts[0] + fraction.padRight(scale, '0'));
}

String formatUnits(BigInt n, int scale) {
  if (scale == 0) return n.toString();
  final s = n.toString().padLeft(scale + 1, '0');
  return '${s.substring(0, s.length - scale)}.${s.substring(s.length - scale)}';
}

BigInt convertAmount(String amount, String currency, String rate, String base) {
  final n = decimalUnits(amount, digits(currency));
  final r = decimalUnits(rate, 8);
  final numerator = n * r * BigInt.from(10).pow(digits(base));
  final denominator = BigInt.from(10).pow(digits(currency) + 8);
  return (numerator + denominator ~/ BigInt.two) ~/ denominator;
}

DateTime? parseDate(String value) {
  if (value.isEmpty) return null;
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throw const FormatException('日期格式应为 YYYY-MM-DD');
  }
  final d = DateTime.tryParse(value);
  if (d == null || dateText(d) != value) throw const FormatException('日期不存在');
  return d;
}

String dateText(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String dayDate(Map<String, dynamic> trip, int day) {
  final start = parseDate(trip['start'] as String? ?? '');
  return start == null || day == 0
      ? ''
      : dateText(DateTime(start.year, start.month, start.day + day - 1));
}

class Record {
  final String id, kind, device;
  final int modified;
  final bool deleted;
  final Map<String, dynamic> data;
  Record(
    this.id,
    this.kind,
    this.device,
    this.modified,
    this.deleted,
    this.data,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'device': device,
    'modified': modified,
    'deleted': deleted,
    'data': data,
  };
  factory Record.fromJson(dynamic raw) {
    if (raw is! Map) throw const FormatException('记录格式错误');
    final m = Map<String, dynamic>.from(raw);
    if (m['id'] is! String ||
        (m['id'] as String).isEmpty ||
        (m['id'] as String).length > 150 ||
        !['trip', 'item', 'order', 'day'].contains(m['kind']) ||
        m['device'] is! String ||
        (m['device'] as String).length > 150 ||
        m['modified'] is! int ||
        m['modified'] < 0 ||
        m['deleted'] is! bool ||
        m['data'] is! Map) {
      throw const FormatException('记录字段无效');
    }
    final data = Map<String, dynamic>.from(m['data']);
    validateData(m['kind'], data);
    return Record(
      m['id'],
      m['kind'],
      m['device'],
      m['modified'],
      m['deleted'],
      data,
    );
  }
  bool newerThan(Record other) =>
      modified > other.modified ||
      (modified == other.modified && device.compareTo(other.device) > 0);
}

void validateData(String kind, Map<String, dynamic> d) {
  if (kind == 'item') validateLocations(d['locations']);
  if (utf8.encode(jsonEncode(d)).length > 100000) {
    throw const FormatException('单条记录过大');
  }
  void string(String key, {int max = 10000}) {
    if (d[key] is! String || (d[key] as String).length > max) {
      throw FormatException('$key 字段无效');
    }
  }

  void day(String key, {bool zero = true}) {
    if (d[key] is! int || d[key] < (zero ? 0 : 1) || d[key] > 3660) {
      throw FormatException('$key 天数无效');
    }
  }

  if (kind == 'trip') {
    string('name', max: 200);
    string('start');
    string('base');
    string('zone');
    string('note');
    day('days', zero: false);
    if ((d['name'] as String).trim().isEmpty ||
        !currencies.contains(d['base'])) {
      throw const FormatException('旅行名称或币种无效');
    }
    parseDate(d['start']);
    if (d.containsKey('preparations')) {
      if (d['preparations'] is! List) throw const FormatException('准备清单无效');
      final ids = <String>{};
      for (final p in d['preparations']) {
        if (p is! Map ||
            p['id'] is! String ||
            !ids.add(p['id']) ||
            p['name'] is! String ||
            (p['name'] as String).trim().isEmpty ||
            (p['name'] as String).length > 200 ||
            p['note'] is! String ||
            (p['note'] as String).length > 10000 ||
            p['due'] is! String ||
            p['done'] is! bool) {
          throw const FormatException('准备事项名称或字段无效');
        }
        parseDate(p['due']);
      }
    }
    tz.getLocation(d['zone']);
    if (d['rates'] is! Map) throw const FormatException('汇率无效');
    for (final e in (d['rates'] as Map).entries) {
      if (!currencies.contains(e.key) ||
          e.value is! String ||
          decimalUnits(e.value, 8) <= BigInt.zero) {
        throw const FormatException('汇率必须大于零');
      }
    }
  } else {
    string('trip', max: 150);
    day('day');
    if (kind == 'item') {
      string('name', max: 200);
      string('type');
      string('note');
      string('booking');
      day('endDay');
      if (!types.contains(d['type']) ||
          d['done'] is! bool ||
          !['不适用', '待预订', '已预订'].contains(d['booking']) ||
          d['fields'] is! Map ||
          d['costs'] is! List) {
        throw const FormatException('活动字段无效');
      }
      if (d['type'] == '住宿' &&
          d['day'] > 0 &&
          d['endDay'] > 0 &&
          d['endDay'] <= d['day']) {
        throw const FormatException('退房日须晚于入住日');
      }
      for (final e in (d['fields'] as Map).entries) {
        if (e.key is! String ||
            e.value is! String ||
            (e.value as String).length > 10000) {
          throw const FormatException('详情字段无效');
        }
      }
      final f = Map<String, dynamic>.from(d['fields']);
      for (final key in ['startDate', 'endDate', 'reservationDate']) {
        parseDate(f[key] ?? '');
      }
      for (final key in ['startZone', 'endZone']) {
        if ((f[key] ?? '') != '') tz.getLocation(f[key]);
      }
      for (final key in ['startTime', 'endTime', 'reservationTime']) {
        if ((f[key] ?? '') != '' &&
            !RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(f[key])) {
          throw const FormatException('时间应为 HH:mm');
        }
      }
      if ((d['costs'] as List).length > 200) {
        throw const FormatException('费用明细过多');
      }
      final ids = <String>{};
      for (final c in d['costs']) {
        if (c is! Map ||
            c['id'] is! String ||
            !ids.add(c['id']) ||
            c['label'] is! String ||
            !currencies.contains(c['currency']) ||
            !categories.contains(c['category']) ||
            c['amount'] is! String) {
          throw const FormatException('费用格式错误');
        }
        if (c['amount'] != '') decimalUnits(c['amount'], digits(c['currency']));
      }
    } else if (kind == 'order') {
      if (d['ids'] is! List ||
          (d['ids'] as List).length > 20000 ||
          (d['ids'] as List).any((x) => x is! String) ||
          (d['ids'] as List).toSet().length != (d['ids'] as List).length) {
        throw const FormatException('排序无效');
      }
    } else {
      if (d.containsKey('explicit') && d['explicit'] is! bool) {
        throw const FormatException('日期显示标记无效');
      }
      string('zone');
      tz.getLocation(d['zone']);
    }
  }
}

List<Record> decodeRecords(String text, {String format = 'howdoi-backup'}) {
  if (utf8.encode(text).length > 20 * 1024 * 1024) {
    throw const FormatException('文件超过 20 MB');
  }
  final m = jsonDecode(text);
  if (m is! Map ||
      m['format'] != format ||
      (format == 'howdoi-sync'
          ? m['version'] != 3
          : ![1, 2, 3].contains(m['version'])) ||
      m['records'] is! List ||
      m['records'].length > 20000) {
    throw const FormatException('不是受支持的 HowDoI 数据文件');
  }
  final rows = (m['records'] as List).map(Record.fromJson).toList();
  if (rows.map((r) => r.id).toSet().length != rows.length) {
    throw const FormatException('文件有重复记录 ID');
  }
  return rows;
}

class Budget {
  final byCurrency = <String, BigInt>{};
  final byCategory = <String, Map<String, BigInt>>{};
  int unknown = 0;
  Budget(Record trip, Iterable<Record> items) {
    for (final item in items) {
      if ((item.data['costs'] as List).isEmpty) unknown++;
      for (final c in item.data['costs']) {
        if (c['amount'] == '') {
          unknown++;
          continue;
        }
        final currency = c['currency'] as String;
        final amount = decimalUnits(c['amount'], digits(currency));
        byCurrency[currency] = (byCurrency[currency] ?? BigInt.zero) + amount;
        final subtotal = byCategory.putIfAbsent(
          c['category'],
          () => <String, BigInt>{},
        );
        subtotal[currency] = (subtotal[currency] ?? BigInt.zero) + amount;
      }
    }
  }
}

void validateLocations(dynamic locations) {
  if (locations == null) return;
  if (locations is! Map || locations.length > 3) {
    throw const FormatException('地点关联格式无效');
  }
  for (final e in locations.entries) {
    final p = e.value;
    if (!['origin', 'destination', 'place'].contains(e.key) ||
        p is! Map ||
        p['lat'] is! num ||
        p['lon'] is! num ||
        !(p['lat'] as num).isFinite ||
        !(p['lon'] as num).isFinite ||
        p['lat'] < -90 ||
        p['lat'] > 90 ||
        p['lon'] < -180 ||
        p['lon'] > 180 ||
        p['crs'] != 'WGS84' ||
        !['osm', 'manual'].contains(p['provider'])) {
      throw const FormatException('地点坐标或供应商不兼容，请使用新版应用');
    }
    for (final k in ['name', 'address', 'id', 'sourceText', 'country']) {
      if (p[k] is! String || (p[k] as String).length > 2000) {
        throw const FormatException('地点信息无效');
      }
    }
  }
}
