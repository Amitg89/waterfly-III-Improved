import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

/// Dart port of the importer's `src/crypto.js` so the app produces
/// `encrypted:v1:` values the Node importer can decrypt.
///
/// Format: PBKDF2-HMAC-SHA256 (100k iterations) -> 32 byte key,
/// AES-256-GCM, payload = salt(32) | iv(12) | authTag(16) | ciphertext.
const String encryptedPrefix = 'encrypted:v1:';

const int _keyLength = 32;
const int _ivLength = 12;
const int _saltLength = 32;
const int _authTagLength = 16;
const int _pbkdf2Iterations = 100000;

class VaultCryptoException implements Exception {
  VaultCryptoException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _EncryptRequest {
  const _EncryptRequest(this.plaintext, this.masterPassword, this.salt, this.iv);

  final String plaintext;
  final String masterPassword;
  final Uint8List salt;
  final Uint8List iv;
}

Uint8List _randomBytes(int length) {
  final Random random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

Uint8List _deriveKey(String password, Uint8List salt) {
  final KeyDerivator derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, _pbkdf2Iterations, _keyLength));

  return derivator.process(Uint8List.fromList(utf8.encode(password)));
}

String _encryptSync(_EncryptRequest request) {
  final Uint8List key = _deriveKey(request.masterPassword, request.salt);
  final GCMBlockCipher cipher = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters<KeyParameter>(
        KeyParameter(key),
        _authTagLength * 8,
        request.iv,
        Uint8List(0),
      ),
    );

  // PointyCastle appends the auth tag to the ciphertext; the importer expects
  // it in front of the ciphertext instead.
  final Uint8List sealed = cipher.process(
    Uint8List.fromList(utf8.encode(request.plaintext)),
  );
  final Uint8List ciphertext = sealed.sublist(
    0,
    sealed.length - _authTagLength,
  );
  final Uint8List authTag = sealed.sublist(sealed.length - _authTagLength);

  final BytesBuilder combined = BytesBuilder()
    ..add(request.salt)
    ..add(request.iv)
    ..add(authTag)
    ..add(ciphertext);

  return encryptedPrefix + base64.encode(combined.toBytes());
}

String _decryptSync(_DecryptRequest request) {
  final Uint8List combined = base64.decode(
    request.encryptedText.substring(encryptedPrefix.length),
  );
  if (combined.length <= _saltLength + _ivLength + _authTagLength) {
    throw VaultCryptoException('Encrypted value is malformed');
  }

  int offset = 0;
  final Uint8List salt = combined.sublist(offset, offset += _saltLength);
  final Uint8List iv = combined.sublist(offset, offset += _ivLength);
  final Uint8List authTag = combined.sublist(offset, offset += _authTagLength);
  final Uint8List ciphertext = combined.sublist(offset);

  final Uint8List key = _deriveKey(request.masterPassword, salt);
  final GCMBlockCipher cipher = GCMBlockCipher(AESEngine())
    ..init(
      false,
      AEADParameters<KeyParameter>(
        KeyParameter(key),
        _authTagLength * 8,
        iv,
        Uint8List(0),
      ),
    );

  final BytesBuilder sealed = BytesBuilder()
    ..add(ciphertext)
    ..add(authTag);

  try {
    return utf8.decode(cipher.process(sealed.toBytes()));
  } on InvalidCipherTextException {
    throw VaultCryptoException(
      'Decryption failed: invalid master password or corrupted data',
    );
  }
}

class _DecryptRequest {
  const _DecryptRequest(this.encryptedText, this.masterPassword);

  final String encryptedText;
  final String masterPassword;
}

bool isEncrypted(String text) => text.startsWith(encryptedPrefix);

/// Encrypts [plaintext] into an `encrypted:v1:` value.
///
/// Key derivation is 100k PBKDF2 rounds, so this runs off the UI isolate.
Future<String> encryptValue(String plaintext, String masterPassword) {
  if (plaintext.isEmpty || masterPassword.isEmpty) {
    throw VaultCryptoException('Value and master password are required');
  }

  return compute(
    _encryptSync,
    _EncryptRequest(
      plaintext,
      masterPassword,
      _randomBytes(_saltLength),
      _randomBytes(_ivLength),
    ),
  );
}

/// Decrypts an `encrypted:v1:` value. Used to verify a master password
/// against a value already present in the config.
Future<String> decryptValue(String encryptedText, String masterPassword) {
  if (!isEncrypted(encryptedText)) {
    throw VaultCryptoException('Value is not in encrypted:v1: format');
  }
  if (masterPassword.isEmpty) {
    throw VaultCryptoException('Master password is required');
  }

  return compute(_decryptSync, _DecryptRequest(encryptedText, masterPassword));
}
