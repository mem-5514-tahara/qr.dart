import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart'; // Import for Shift-JIS encoding
import 'bit_buffer.dart';
import 'mode.dart' as qr_mode;

abstract class QrDatum {
  int get mode;
  int get length;
  void write(QrBitBuffer buffer);
}

class QrByte implements QrDatum {
  @override
  final int mode = qr_mode.mode8bitByte;
  final Uint8List _data;

  factory QrByte(String input) =>
      QrByte.fromUint8List(utf8.encoder.convert(input));

  QrByte.fromUint8List(Uint8List input) : _data = input;

  factory QrByte.fromByteData(ByteData input) =>
      QrByte.fromUint8List(input.buffer.asUint8List());

  @override
  int get length => _data.length;

  @override
  void write(QrBitBuffer buffer) {
    for (final v in _data) {
      buffer.put(v, 8);
    }
  }
}

/// Encodes numbers (0-9) 10 bits per 3 digits.
class QrNumeric implements QrDatum {
  factory QrNumeric.fromString(String numberString) {
    final newList = Uint8List(numberString.length);
    var count = 0;
    for (var char in numberString.codeUnits) {
      if (char < 0x30 || char > 0x39) {
        throw ArgumentError('string can only contain alpha numeric 0-9');
      }
      newList[count++] = char - 0x30;
    }
    return QrNumeric._(newList);
  }

  QrNumeric._(this._data);

  final Uint8List _data;

  @override
  final int mode = qr_mode.modeNumber;

  @override
  void write(QrBitBuffer buffer) {
    // Walk through the list of number; attempting to encode up to 3 at a time.
    // Write (N *3 + 1) bits.
    final leftOver = _data.length % 3;

    final efficientGrab = _data.length - leftOver;
    for (var i = 0; i < efficientGrab; i += 3) {
      final encoded = _data[i] * 100 + _data[i + 1] * 10 + _data[i + 2];
      buffer.put(encoded, 10);
    }
    if (leftOver > 1) {
      // 2 bytes
      buffer.put(_data[_data.length - 2] * 10 + _data[_data.length - 1], 7);
    } else if (leftOver > 0) {
      // 1 byte
      buffer.put(_data.last, 4);
    }
  }

  // This is still the *number of characters to encode*, not encoded length.
  @override
  int get length => _data.length;
}

/// Encodes numbers (0-9) 10 bits per 3 digits.
class QrAlphaNumeric implements QrDatum {
  static const alphaNumTable = r'0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:';
  // Note: '-' anywhere in this string is a range character.
  static final validationRegex =
      RegExp(r'^[-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+./:]+$');
  static final encodeArray = () {
    final array = List<int?>.filled(91, null);
    for (var i = 0; i < alphaNumTable.length; i++) {
      final char = alphaNumTable.codeUnitAt(i);
      array[char] = i;
    }
    return array;
  }();

  final String _string;

  factory QrAlphaNumeric.fromString(String alphaNumeric) {
    if (!alphaNumeric.contains(validationRegex)) {
      throw ArgumentError('String does not contain valid ALPHA-NUM '
          'character set: $alphaNumeric');
    }
    return QrAlphaNumeric._(alphaNumeric);
  }

  QrAlphaNumeric._(this._string);

  @override
  final int mode = qr_mode.modeAlphaNum;

  @override
  void write(QrBitBuffer buffer) {
    // Walk through the list of number; attempting to encode up to 2 at a time.
    // Write (N *5 + 1) bits.
    final leftOver = _string.length % 2;

    final efficientGrab = _string.length - leftOver;
    for (var i = 0; i < efficientGrab; i += 2) {
      final encoded = encodeArray[_string.codeUnitAt(i)]! * 45 +
          encodeArray[_string.codeUnitAt(i + 1)]!;
      buffer.put(encoded, 11);
    }
    if (leftOver > 0) {
      // N*5 + 1 = 6
      buffer.put(encodeArray[_string.codeUnitAt(_string.length - 1)]!, 6);
    }
  }

  // This is still the *number of characters to encode*, not encoded length.
  @override
  int get length => _string.length;
}

/// Encodes Kanji characters in Shift-JIS format.
class QrKanji implements QrDatum {
  @override
  final int mode = qr_mode.modeKanji;
  final Uint8List _data;

  factory QrKanji(String input) {
    final sjisEncoder = shiftJis.encoder;
    try {
      final sjisBytes = sjisEncoder.convert(input);
      if (sjisBytes.length % 2 != 0) {
        throw ArgumentError(
            'Input string length must be an even number of bytes for Kanji Mode');
      }
      return QrKanji._(Uint8List.fromList(sjisBytes));
    } catch (e) {
      throw ArgumentError('Unsupported Kanji character or encoding error: $e');
    }
  }

  QrKanji._(this._data);

  @override
  int get length => _data.length ~/ 2;

  @override
  void write(QrBitBuffer buffer) {
    for (var i = 0; i < _data.length; i += 2) {
      // Combine two Shift-JIS bytes into a single integer.
      final code = (_data[i] << 8) | _data[i + 1];

      int encoded;
      if (0x8140 <= code && code <= 0x9FFC) {
        // JISX0208 range
        encoded = code - 0x8140;
        if (encoded >= 0x40) {
          encoded--;
        }
      } else if (0xE040 <= code && code <= 0xEBBF) {
        // Shift-JIS extended range
        encoded = code - 0xC140;
      } else {
        throw ArgumentError(
            'Unsupported Kanji character: ${code.toRadixString(16)}');
      }

      // Encode into 13 bits.
      buffer.put(encoded, 13);
    }
  }
}
