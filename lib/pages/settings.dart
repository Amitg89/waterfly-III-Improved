import 'package:animations/animations.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:logging/logging.dart';
import 'package:material_color_utilities/material_color_utilities.dart'
    show CorePalette;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:waterflyiii/auth.dart';
import 'package:waterflyiii/extensions.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/notificationlistener.dart';
import 'package:waterflyiii/pages/settings/debug.dart';
import 'package:waterflyiii/pages/settings/notifications.dart';
import 'package:waterflyiii/settings.dart';

final Logger log = Logger("Pages.Settings");

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => SettingsPageState();
}

class SettingsPageState extends State<SettingsPage>
    with SingleTickerProviderStateMixin {
  final Logger log = Logger("Pages.Settings.Page");

  @override
  Widget build(BuildContext context) {
    log.finest(() => "build()");

    final SettingsProvider settings = context.read<SettingsProvider>();

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      primary: false,
      children: <Widget>[
        ListTile(
          title: Text(S.of(context).settingsLanguage),
          subtitle: Text(S.of(context).localeName),
          leading: const CircleAvatar(child: Icon(Icons.language)),
          onTap: () {
            showDialog<Locale?>(
              context: context,
              builder: (BuildContext context) => const LanguageDialog(),
            ).then((Locale? locale) async {
              if (locale == null) {
                return;
              }
              await settings.setLocale(locale);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                const QuickActions().setShortcutItems(<ShortcutItem>[
                  ShortcutItem(
                    type: "action_transaction_add",
                    localizedTitle: S.of(context).transactionTitleAdd,
                    icon: "action_icon_add",
                  ),
                ]);
              });
            });
          },
        ),
        FutureBuilder<CorePalette?>(
          future: DynamicColorPlugin.getCorePalette(),
          builder: (
            BuildContext context,
            AsyncSnapshot<CorePalette?> snapshot,
          ) {
            String dynamicColor = "";
            bool dynamicColorAvailable = false;
            if (snapshot.connectionState == ConnectionState.done &&
                snapshot.hasData &&
                snapshot.data != null) {
              // Dynamic color support available
              dynamicColorAvailable = true;
              if (context.select((SettingsProvider s) => s.dynamicColors)) {
                dynamicColor = " - ${S.of(context).settingsThemeDynamicColors}";
              }
            }
            return ListTile(
              title: Text(S.of(context).settingsTheme),
              subtitle: Text(
                "${S.of(context).settingsThemeValue(context.select((SettingsProvider s) => s.theme).toString().split('.').last)}$dynamicColor",
              ),
              leading: const CircleAvatar(child: Icon(Icons.format_paint)),
              onTap: () {
                showDialog<ThemeMode?>(
                  context: context,
                  builder:
                      (BuildContext context) => ThemeDialog(
                        dynamicColorAvailable: dynamicColorAvailable,
                      ),
                ).then((ThemeMode? theme) {
                  if (theme == null) {
                    return;
                  }
                  settings.setTheme(theme);
                });
              },
            );
          },
        ),
        SwitchListTile(
          title: Text(S.of(context).settingsUseServerTimezone),
          subtitle: Text(S.of(context).settingsUseServerTimezoneHelp),
          value: context.select((SettingsProvider s) => s.useServerTime),
          secondary: CircleAvatar(
            child: Icon(
              context.select((SettingsProvider s) => s.useServerTime)
                  ? Icons.schedule
                  : Icons.schedule_outlined,
            ),
          ),
          onChanged: (bool value) async {
            await context.read<FireflyService>().tzHandler.setUseServerTime(
              value,
            );
            settings.useServerTime = value;
          },
        ),
        const Divider(),
        SwitchListTile(
          title: Text(S.of(context).settingsLockscreen),
          subtitle: Text(S.of(context).settingsLockscreenHelp),
          value: context.select((SettingsProvider s) => s.lock),
          secondary: CircleAvatar(
            child: Icon(
              context.select((SettingsProvider s) => s.lock)
                  ? Icons.lock
                  : Icons.lock_outline,
            ),
          ),
          onChanged: (bool value) async {
            final S l10n = S.of(context);
            final ScaffoldMessengerState msg = ScaffoldMessenger.of(context);
            if (value == true) {
              final LocalAuthentication auth = LocalAuthentication();
              final bool canAuth =
                  await auth.isDeviceSupported() ||
                  await auth.canCheckBiometrics;
              if (!canAuth) {
                log.warning("no auth method supported");
                return;
              }
              log.finest("trying authentication");
              late bool authed;
              try {
                authed = await auth.authenticate(
                  localizedReason: l10n.settingsLockscreenInitial,
                );
              } catch (e, stackTrace) {
                log.severe("auth failed", e, stackTrace);
                msg.showSnackBar(
                  SnackBar(
                    content: Text(l10n.errorUnknown),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
                return;
              }

              if (!authed) {
                log.warning("authentication was cancelled");
                return;
              }
            }
            settings.lock = value;
          },
        ),
        const Divider(),
        FutureBuilder<NotificationListenerStatus>(
          future: nlStatus(),
          builder: (
            BuildContext context,
            AsyncSnapshot<NotificationListenerStatus> snapshot,
          ) {
            final S l10n = S.of(context);

            late String subtitle;
            if (snapshot.connectionState == ConnectionState.done &&
                snapshot.hasData) {
              if (!snapshot.data!.servicePermission ||
                  !snapshot.data!.notificationPermission) {
                subtitle = l10n.settingsNLPermissionNotGranted;
              } else if (!snapshot.data!.serviceRunning) {
                subtitle = l10n.settingsNLServiceStopped;
              } else {
                subtitle = l10n.settingsNLServiceRunning;
              }
            } else if (snapshot.hasError) {
              log.severe(
                "error getting nlStatus",
                snapshot.error,
                snapshot.stackTrace,
              );
              subtitle = S
                  .of(context)
                  .settingsNLServiceCheckingError(snapshot.error.toString());
            } else {
              subtitle = S.of(context).settingsNLServiceChecking;
            }
            return OpenContainer(
              openBuilder:
                  (BuildContext context, Function closedContainer) =>
                      const SettingsNotifications(),
              openColor: Theme.of(context).cardColor,
              closedColor: Theme.of(context).cardColor,
              closedElevation: 0,
              closedBuilder:
                  (BuildContext context, Function openContainer) => ListTile(
                    title: Text(S.of(context).settingsNotificationListener),
                    subtitle: Text(subtitle, maxLines: 2),
                    leading: const CircleAvatar(
                      child: Icon(Icons.notifications),
                    ),
                    onTap: () => openContainer(),
                  ),
              onClosed: (_) => setState(() {}),
            );
          },
        ),
        const Divider(),
        ListTile(
          title: Text(S.of(context).settingsGeminiApiKey),
          subtitle: Text(S.of(context).settingsGeminiApiKeySubtitle),
          leading: const CircleAvatar(child: Icon(Icons.psychology)),
          onTap:
              () => showDialog<void>(
                context: context,
                builder:
                    (BuildContext context) => _GeminiApiKeyDialog(
                      onSave: (String key) async {
                        await context.read<FireflyService>().setGeminiApiKey(
                          key,
                        );
                        if (context.mounted) {
                          Navigator.of(context).pop();
                        }
                      },
                    ),
              ),
        ),
        SwitchListTile(
          title: Text(S.of(context).settingsShowAiBubble),
          value: context.select((SettingsProvider s) => s.aiBubbleVisible),
          secondary: const CircleAvatar(child: Icon(Icons.auto_awesome)),
          onChanged: (bool value) => settings.setAiBubbleVisible(value),
        ),
        ListTile(
          title: Text(S.of(context).settingsCreditCardCycleDay),
          subtitle: Text(
            S
                .of(context)
                .settingsCreditCardCycleDaySubtitle(
                  context.select((SettingsProvider s) => s.creditCardCycleDay),
                ),
          ),
          leading: const CircleAvatar(child: Icon(Icons.credit_card)),
          onTap:
              () => showDialog<int>(
                context: context,
                builder:
                    (BuildContext context) =>
                        CycleDayDialog(currentDay: settings.creditCardCycleDay),
              ).then((int? day) {
                if (day == null) {
                  return;
                }
                settings.setCreditCardCycleDay(day);
              }),
        ),
        ListTile(
          title: Text(S.of(context).settingsSalaryKeywords),
          subtitle: Text(S.of(context).settingsSalaryKeywordsSubtitle),
          leading: const CircleAvatar(child: Icon(Icons.payments)),
          onTap:
              () => showDialog<String>(
                context: context,
                builder:
                    (BuildContext context) => SalaryKeywordsDialog(
                      currentKeywords: settings.salaryKeywords,
                    ),
              ).then((String? keywords) {
                if (keywords == null) {
                  return;
                }
                settings.setSalaryKeywords(keywords);
              }),
        ),
        const Divider(),
        ListTile(
          title: Text(S.of(context).settingsFAQ),
          subtitle: Text(S.of(context).settingsFAQHelp),
          leading: const CircleAvatar(child: Icon(Icons.question_answer)),
          onTap: () async {
            final Uri uri = Uri.parse(
              "https://github.com/dreautall/waterfly-iii/blob/master/FAQ.md",
            );
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri);
            } else {
              throw Exception("Could not open URL");
            }
          },
        ),
        FutureBuilder<PackageInfo>(
          future: PackageInfo.fromPlatform(),
          builder: (BuildContext context, AsyncSnapshot<PackageInfo> snapshot) {
            return ListTile(
              title: Text(S.of(context).settingsVersion),
              subtitle: Text(
                (snapshot.data != null)
                    ? "${snapshot.data!.appName}, ${snapshot.data!.version}+${snapshot.data!.buildNumber}"
                    : S.of(context).settingsVersionChecking,
              ),
              leading: const CircleAvatar(
                child: Icon(Icons.info_outline_rounded),
              ),
              onTap:
                  () => showDialog(
                    context: context,
                    builder: (BuildContext context) => const DebugDialog(),
                  ),
            );
          },
        ),
      ],
    );
  }
}

class LanguageDialog extends StatelessWidget {
  const LanguageDialog({super.key});

  @override
  Widget build(BuildContext context) {
    debugPrint("current locale: ${S.of(context).localeName}");
    return SimpleDialog(
      title: Text(S.of(context).settingsDialogLanguageTitle),
      children: <Widget>[
        RadioGroup<Locale>(
          groupValue: LocaleExt.fromLanguageTag(S.of(context).localeName),
          onChanged: (Locale? locale) {
            Navigator.pop(context, locale);
          },
          child: Column(
            children: <Widget>[
              ...S.supportedLocales.map(
                (Locale locale) => RadioListTile<Locale>(
                  value: locale,
                  title: Text(locale.toLanguageTag()),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class ThemeDialog extends StatelessWidget {
  const ThemeDialog({super.key, required this.dynamicColorAvailable});

  final bool dynamicColorAvailable;

  @override
  Widget build(BuildContext context) {
    final SettingsProvider settings = context.read<SettingsProvider>();
    return SimpleDialog(
      title: Text(S.of(context).settingsDialogThemeTitle),
      children: <Widget>[
        dynamicColorAvailable
            ? SwitchListTile(
              title: Text(S.of(context).settingsThemeDynamicColors),
              value: context.select((SettingsProvider s) => s.dynamicColors),
              isThreeLine: false,
              onChanged: (bool value) => settings.dynamicColors = value,
            )
            : const SizedBox.shrink(),
        RadioGroup<ThemeMode>(
          groupValue: settings.theme,
          onChanged: (ThemeMode? theme) {
            Navigator.pop(context, theme);
          },
          child: Column(
            children: <Widget>[
              ...ThemeMode.values.map(
                (ThemeMode theme) => RadioListTile<ThemeMode>(
                  value: theme,
                  title: Text(
                    S
                        .of(context)
                        .settingsThemeValue(theme.toString().split('.').last),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class CycleDayDialog extends StatelessWidget {
  const CycleDayDialog({super.key, required this.currentDay});

  final int currentDay;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(S.of(context).settingsCreditCardCycleDayDialogTitle),
      content: SizedBox(
        width: double.maxFinite,
        child: GridView.count(
          shrinkWrap: true,
          crossAxisCount: 7,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          children: List<Widget>.generate(28, (int index) {
            final int day = index + 1;
            final Widget label = Text("$day");
            return day == currentDay
                ? FilledButton(
                  style: FilledButton.styleFrom(padding: EdgeInsets.zero),
                  onPressed: () => Navigator.of(context).pop(day),
                  child: label,
                )
                : TextButton(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  onPressed: () => Navigator.of(context).pop(day),
                  child: label,
                );
          }),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
      ],
    );
  }
}

class SalaryKeywordsDialog extends StatefulWidget {
  const SalaryKeywordsDialog({super.key, required this.currentKeywords});

  final String currentKeywords;

  @override
  State<SalaryKeywordsDialog> createState() => _SalaryKeywordsDialogState();
}

class _SalaryKeywordsDialogState extends State<SalaryKeywordsDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.currentKeywords,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);
    return AlertDialog(
      title: Text(l10n.settingsSalaryKeywordsDialogTitle),
      content: TextFormField(
        controller: _controller,
        decoration: InputDecoration(
          labelText: l10n.settingsSalaryKeywords,
          helperText: l10n.settingsSalaryKeywordsDialogHelp,
          helperMaxLines: 4,
          filled: true,
        ),
        maxLines: 3,
        minLines: 1,
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(MaterialLocalizations.of(context).saveButtonLabel),
        ),
      ],
    );
  }
}

class _GeminiApiKeyDialog extends StatefulWidget {
  const _GeminiApiKeyDialog({required this.onSave});

  final Future<void> Function(String key) onSave;

  @override
  State<_GeminiApiKeyDialog> createState() => _GeminiApiKeyDialogState();
}

class _GeminiApiKeyDialogState extends State<_GeminiApiKeyDialog> {
  final TextEditingController _controller = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  bool _obscureKey = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String? text = data?.text;
    if (text != null && text.isNotEmpty && mounted) {
      setState(() {
        _controller.text = text;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);
    return AlertDialog(
      title: Text(l10n.settingsGeminiApiKeyDialogTitle),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          decoration: InputDecoration(
            labelText: l10n.settingsGeminiApiKeyDialogLabel,
            filled: true,
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  icon: const Icon(Icons.content_paste),
                  onPressed: _pasteFromClipboard,
                  tooltip: MaterialLocalizations.of(context).pasteButtonLabel,
                ),
                IconButton(
                  icon: Icon(
                    _obscureKey ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () {
                    setState(() {
                      _obscureKey = !_obscureKey;
                    });
                  },
                  tooltip: _obscureKey ? 'Show key' : 'Hide key',
                ),
              ],
            ),
          ),
          obscureText: _obscureKey,
          enableInteractiveSelection: true,
          validator: (String? value) {
            if (value == null || value.trim().isEmpty) {
              return l10n.errorFieldRequired;
            }
            return null;
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () async {
            if (!_formKey.currentState!.validate()) return;
            await widget.onSave(_controller.text.trim());
          },
          child: Text(l10n.settingsGeminiApiKeyDialogSave),
        ),
      ],
    );
  }
}
