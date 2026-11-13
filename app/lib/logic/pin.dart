/// The app-lock PIN is never stored: only a salted hash of it.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

String newSalt() {
  final r = Random.secure();
  return base64Url.encode(List<int>.generate(12, (_) => r.nextInt(256)));
}

String hashPin(String pin, String salt) => sha256.convert(utf8.encode('$salt:$pin')).toString();

bool verifyPin(String pin, String salt, String hash) => hash.isNotEmpty && hashPin(pin, salt) == hash;
