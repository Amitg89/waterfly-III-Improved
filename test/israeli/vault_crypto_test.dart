import 'package:flutter_test/flutter_test.dart';
import 'package:waterflyiii/israeli/vault_crypto.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Produced by the importer's `src/crypto.js` (node) for value
  // "TestPass123!" with master password "master-secret-42".
  const String nodeReference =
      'encrypted:v1:iEa850VypRuPZlYyq8xPZ8feiqCNW31uiLwCwWTcVechHWs0gSp2Rr/wGN7hTMv4D/V2un5HLzjx/7whtTW8MB0MHdsmk3iz';

  test('decrypts a value produced by the Node importer', () async {
    expect(
      await decryptValue(nodeReference, 'master-secret-42'),
      'TestPass123!',
    );
  });

  test('rejects a wrong master password', () {
    expect(
      () => decryptValue(nodeReference, 'wrong-password'),
      throwsA(isA<VaultCryptoException>()),
    );
  });

  test('round-trips its own output', () async {
    final String encrypted = await encryptValue('שלום-secret', 'pw');
    expect(encrypted.startsWith(encryptedPrefix), isTrue);
    expect(await decryptValue(encrypted, 'pw'), 'שלום-secret');
  });

  test('prints an app-encrypted value for the node interop check', () async {
    // ignore: avoid_print
    print(await encryptValue('TestPass123!', 'master-secret-42'));
  });
}
