import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:logging/logging.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/israeli/vault_crypto.dart';

final Logger log = Logger("Pages.Settings.PasswordEncryptor");

const String _masterPasswordKey = 'importerMasterPassword';

class PasswordEncryptorPage extends StatefulWidget {
  const PasswordEncryptorPage({super.key});

  @override
  State<PasswordEncryptorPage> createState() => _PasswordEncryptorPageState();
}

class _PasswordEncryptorPageState extends State<PasswordEncryptorPage> {
  final TextEditingController _valueController = TextEditingController();
  final TextEditingController _masterController = TextEditingController();
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: true),
  );

  bool _obscureValue = true;
  bool _obscureMaster = true;
  bool _rememberMaster = false;
  bool _working = false;
  String? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaitedLoadMaster();
  }

  @override
  void dispose() {
    _valueController.dispose();
    _masterController.dispose();
    super.dispose();
  }

  void unawaitedLoadMaster() {
    _loadStoredMaster().catchError((Object e, StackTrace s) {
      log.warning("could not load stored master password", e, s);
    });
  }

  Future<void> _loadStoredMaster() async {
    final String? stored = await _storage.read(key: _masterPasswordKey);
    if (stored == null || !mounted) {
      return;
    }
    if (!await _authenticate(S.of(context).passwordEncryptorUnlockReason)) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _masterController.text = stored;
      _rememberMaster = true;
    });
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<bool> _authenticate(String reason) async {
    final S l10n = S.of(context);
    try {
      if (await LocalAuthentication().authenticate(localizedReason: reason)) {
        return true;
      }
      _showMessage(l10n.passwordEncryptorErrorAuthFailed);
    } on LocalAuthException catch (e, stackTrace) {
      log.warning("device auth failed (${e.code})", e, stackTrace);
      switch (e.code) {
        case LocalAuthExceptionCode.userCanceled:
        case LocalAuthExceptionCode.systemCanceled:
        case LocalAuthExceptionCode.timeout:
          break;
        case LocalAuthExceptionCode.noCredentialsSet:
        case LocalAuthExceptionCode.noBiometricsEnrolled:
        case LocalAuthExceptionCode.noBiometricHardware:
          _showMessage(l10n.passwordEncryptorErrorNoDeviceLock);
        default:
          _showMessage(l10n.passwordEncryptorErrorAuthFailed);
      }
    } catch (e, stackTrace) {
      log.severe("device auth failed", e, stackTrace);
      _showMessage(l10n.passwordEncryptorErrorAuthFailed);
    }
    return false;
  }

  Future<void> _onRememberChanged(bool value) async {
    if (!value) {
      await _storage.delete(key: _masterPasswordKey);
      setState(() => _rememberMaster = false);
      return;
    }
    if (!await _authenticate(S.of(context).passwordEncryptorUnlockReason)) {
      return;
    }
    setState(() => _rememberMaster = true);
  }

  Future<void> _encrypt() async {
    final S l10n = S.of(context);
    final String value = _valueController.text;
    final String master = _masterController.text;

    if (value.isEmpty || master.isEmpty) {
      setState(() {
        _error = l10n.passwordEncryptorErrorEmpty;
        _result = null;
      });
      return;
    }

    setState(() {
      _working = true;
      _error = null;
      _result = null;
    });

    try {
      final String encrypted = await encryptValue(value, master);
      if (_rememberMaster) {
        await _storage.write(key: _masterPasswordKey, value: master);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _result = encrypted;
        _working = false;
      });
    } catch (e, stackTrace) {
      log.severe("encryption failed", e, stackTrace);
      if (!mounted) {
        return;
      }
      setState(() {
        _error = l10n.passwordEncryptorErrorFailed;
        _working = false;
      });
    }
  }

  Future<void> _copy() async {
    final S l10n = S.of(context);
    final ScaffoldMessengerState msg = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _result!));
    msg.showSnackBar(
      SnackBar(
        content: Text(l10n.passwordEncryptorCopied),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);
    final ThemeData theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Text(
          l10n.passwordEncryptorIntro,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _valueController,
          obscureText: _obscureValue,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: l10n.passwordEncryptorNewPasswordLabel,
            prefixIcon: const Icon(Icons.password),
            suffixIcon: IconButton(
              icon: Icon(
                _obscureValue ? Icons.visibility : Icons.visibility_off,
              ),
              onPressed: () => setState(() => _obscureValue = !_obscureValue),
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _masterController,
          obscureText: _obscureMaster,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: l10n.passwordEncryptorMasterPasswordLabel,
            prefixIcon: const Icon(Icons.key),
            suffixIcon: IconButton(
              icon: Icon(
                _obscureMaster ? Icons.visibility : Icons.visibility_off,
              ),
              onPressed: () => setState(() => _obscureMaster = !_obscureMaster),
            ),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.passwordEncryptorRememberMaster),
          subtitle: Text(l10n.passwordEncryptorRememberMasterHelp),
          value: _rememberMaster,
          onChanged: _onRememberChanged,
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _working ? null : _encrypt,
          icon: _working
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.lock),
          label: Text(l10n.passwordEncryptorEncryptButton),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 16),
          Text(
            _error!,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        if (_result != null) ...<Widget>[
          const SizedBox(height: 24),
          Card(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    l10n.passwordEncryptorResultTitle,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    _result!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: "monospace",
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: FilledButton.tonalIcon(
                      onPressed: _copy,
                      icon: const Icon(Icons.copy),
                      label: Text(l10n.passwordEncryptorCopy),
                    ),
                  ),
                  const Divider(),
                  const SizedBox(height: 4),
                  Text(
                    l10n.passwordEncryptorResultHint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
