import 'package:chopper/chopper.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' as intl;
import 'package:provider/provider.dart';
import 'package:waterflyiii/auth.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/generated/swagger_fireflyiii_api/firefly_iii.swagger.dart';
import 'package:waterflyiii/settings.dart';

class DashboardFilterDialog extends StatefulWidget {
  const DashboardFilterDialog({super.key});

  @override
  State<DashboardFilterDialog> createState() => _DashboardFilterDialogState();
}

class _DashboardFilterDialogState extends State<DashboardFilterDialog> {
  late DashboardDateRange _range;
  late DateTime? _customStart;
  late DateTime? _customEnd;
  late bool _selectAccounts;
  late Set<String> _selectedIds;
  late Future<(
    Response<AccountArray>,
    Response<AccountArray>,
  )> _accountsFuture;

  @override
  void initState() {
    super.initState();
    final SettingsProvider settings = context.read<SettingsProvider>();
    _range = settings.dashboardDateRange;
    _customStart = settings.dashboardDateRangeStart;
    _customEnd = settings.dashboardDateRangeEnd;
    _selectAccounts = settings.dashboardAccountIds.isNotEmpty;
    _selectedIds = Set<String>.from(settings.dashboardAccountIds);
    final FireflyIii api = context.read<FireflyService>().api;
    _accountsFuture = Future<(Response<AccountArray>, Response<AccountArray>)>(
        () async {
      final Response<AccountArray> r1 =
          await api.v1AccountsGet(type: AccountTypeFilter.asset);
      final Response<AccountArray> r2 =
          await api.v1AccountsGet(type: AccountTypeFilter.liabilities);
      return (r1, r2);
    });
  }

  String _rangeLabel(BuildContext context, DashboardDateRange r) {
    switch (r) {
      case DashboardDateRange.last7Days:
        return S.of(context).homeMainFilterLast7Days;
      case DashboardDateRange.last30Days:
        return S.of(context).homeMainFilterLast30Days;
      case DashboardDateRange.currentMonth:
        return S.of(context).homeMainFilterCurrentMonth;
      case DashboardDateRange.last3Months:
        return S.of(context).homeMainFilterLast3Months;
      case DashboardDateRange.last12Months:
        return S.of(context).homeMainFilterLast12Months;
      case DashboardDateRange.custom:
        return S.of(context).homeMainFilterCustomRange;
    }
  }

  Future<void> _onApply() async {
    final SettingsProvider settings = context.read<SettingsProvider>();
    await settings.setDashboardDateRange(_range);
    if (_range == DashboardDateRange.custom &&
        _customStart != null &&
        _customEnd != null &&
        !_customStart!.isAfter(_customEnd!)) {
      await settings.setDashboardDateRangeCustom(_customStart!, _customEnd!);
    }
    await settings.setDashboardAccountIds(
      _selectAccounts ? _selectedIds.toList() : <String>[],
    );
    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final S l10n = S.of(context);
    return AlertDialog(
      title: Text(l10n.homeMainFilterTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(l10n.homeMainFilterTimeFrame),
            const SizedBox(height: 8),
            DropdownButtonFormField<DashboardDateRange>(
              value: _range,
              items: DashboardDateRange.values
                  .map(
                    (DashboardDateRange r) => DropdownMenuItem<DashboardDateRange>(
                      value: r,
                      child: Text(_rangeLabel(context, r)),
                    ),
                  )
                  .toList(),
              onChanged: (DashboardDateRange? value) {
                if (value != null) {
                  setState(() {
                    _range = value;
                    if (value == DashboardDateRange.custom &&
                        _customStart == null &&
                        _customEnd == null) {
                      final DateTime now = DateTime.now();
                      _customStart = now.subtract(const Duration(days: 30));
                      _customEnd = now;
                    }
                  });
                }
              },
            ),
            if (_range == DashboardDateRange.custom) ...<Widget>[
              const SizedBox(height: 16),
              ListTile(
                title: Text(_customStart != null
                    ? intl.DateFormat.yMMMd().format(_customStart!)
                    : 'Start'),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final DateTime? picked = await showDatePicker(
                    context: context,
                    initialDate: _customStart ?? DateTime.now(),
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null && mounted) {
                    setState(() {
                      _customStart = picked;
                      if (_customEnd != null && _customEnd!.isBefore(picked)) {
                        _customEnd = picked;
                      }
                    });
                  }
                },
              ),
              ListTile(
                title: Text(_customEnd != null
                    ? intl.DateFormat.yMMMd().format(_customEnd!)
                    : 'End'),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final DateTime? picked = await showDatePicker(
                    context: context,
                    initialDate: _customEnd ?? DateTime.now(),
                    firstDate: _customStart ?? DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null && mounted) {
                    setState(() {
                      _customEnd = picked;
                      if (_customStart != null &&
                          _customStart!.isAfter(picked)) {
                        _customStart = picked;
                      }
                    });
                  }
                },
              ),
            ],
            const SizedBox(height: 24),
            Text(l10n.homeMainFilterAccounts),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: <ButtonSegment<bool>>[
                ButtonSegment<bool>(
                  value: false,
                  label: Text(l10n.homeMainFilterAllAccounts),
                ),
                ButtonSegment<bool>(
                  value: true,
                  label: Text(l10n.homeMainFilterSelectAccounts),
                ),
              ],
              selected: <bool>{_selectAccounts},
              onSelectionChanged: (Set<bool> selected) {
                setState(() => _selectAccounts = selected.first);
              },
            ),
            if (_selectAccounts) ...<Widget>[
              const SizedBox(height: 12),
              SizedBox(
                height: 200,
                child: FutureBuilder<(
                  Response<AccountArray>,
                  Response<AccountArray>,
                )>(
                  future: _accountsFuture,
                  builder: (
                    BuildContext context,
                    AsyncSnapshot<(
                      Response<AccountArray>,
                      Response<AccountArray>,
                    )> snapshot,
                  ) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError || !snapshot.hasData) {
                      return Center(
                        child: Text(
                          snapshot.hasError
                              ? snapshot.error.toString()
                              : 'Failed to load accounts',
                        ),
                      );
                    }
                    final List<AccountRead> accounts = <AccountRead>[
                      ...?snapshot.data!.$1.body?.data,
                      ...?snapshot.data!.$2.body?.data,
                    ];
                    return ListView.builder(
                      itemCount: accounts.length,
                      itemBuilder: (BuildContext context, int index) {
                        final AccountRead acc = accounts[index];
                        // ignore: dead_null_aware_expression - AccountRead.id is String? in API
                        final String id = acc.id ?? '';
                        final String name = acc.attributes.name;
                        return CheckboxListTile(
                          value: _selectedIds.contains(id),
                          title: Text(name),
                          onChanged: (bool? value) {
                            setState(() {
                              if (value ?? false) {
                                _selectedIds.add(id);
                              } else {
                                _selectedIds.remove(id);
                              }
                            });
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () => _onApply(),
          child: Text(MaterialLocalizations.of(context).saveButtonLabel),
        ),
      ],
    );
  }
}
