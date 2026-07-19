import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:waterflyiii/auth.dart';
import 'package:waterflyiii/extensions.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/generated/swagger_fireflyiii_api/firefly_iii.swagger.dart';
import 'package:waterflyiii/israeli/accounts_service.dart';
import 'package:waterflyiii/israeli/transaction_row.dart';
import 'package:waterflyiii/pages/home/banks/bank_detail.dart';
import 'package:waterflyiii/theme.dart';

class HomeBanks extends StatefulWidget {
  const HomeBanks({super.key});

  @override
  State<HomeBanks> createState() => _HomeBanksState();
}

class _HomeBanksState extends State<HomeBanks>
    with AutomaticKeepAliveClientMixin {
  final Logger log = Logger("Pages.Home.Banks");

  late Future<List<AccountRead>> _accountsFuture;

  @override
  void initState() {
    super.initState();
    _accountsFuture = fetchBankAccounts(context.read<FireflyService>().api);
  }

  @override
  bool get wantKeepAlive => true;

  Future<void> _refresh() async {
    final Future<List<AccountRead>> future = fetchBankAccounts(
      context.read<FireflyService>().api,
    );
    setState(() {
      _accountsFuture = future;
    });
    try {
      await future;
    } catch (_) {
      // Error is surfaced by the FutureBuilder.
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    log.fine(() => "build()");

    return FutureBuilder<List<AccountRead>>(
      future: _accountsFuture,
      builder: (
        BuildContext context,
        AsyncSnapshot<List<AccountRead>> snapshot,
      ) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          log.severe(
            "error fetching bank accounts",
            snapshot.error,
            snapshot.stackTrace,
          );
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(
                  Icons.error_outline,
                  size: 64,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  S.of(context).errorUnknown,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _refresh,
                  child: Text(S.of(context).generalRetry),
                ),
              ],
            ),
          );
        }
        final List<AccountRead> accounts = snapshot.data!;
        return RefreshIndicator(
          onRefresh: _refresh,
          child:
              accounts.isEmpty
                  ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: <Widget>[
                      const SizedBox(height: 128),
                      Center(child: Text(S.of(context).banksNoAccounts)),
                    ],
                  )
                  : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: accounts.length,
                    itemBuilder:
                        (BuildContext context, int index) =>
                            _bankRow(context, accounts[index]),
                  ),
        );
      },
    );
  }

  /// Vault-styled bank row: surface card with hairline gold outline, a
  /// rounded icon square and the balance trailing.
  Widget _bankRow(BuildContext context, AccountRead account) {
    final double balance =
        double.tryParse(account.attributes.currentBalance ?? "") ?? 0;
    final CurrencyRead currency = currencyFromAccount(context, account);
    final String? accountNumber = account.attributes.accountNumber;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final MoneyColors mc = Theme.of(context).extension<MoneyColors>()!;

    return Container(
      margin: const EdgeInsetsDirectional.fromSTEB(12, 4, 12, 4),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.outline, width: 1),
      ),
      clipBehavior: Clip.hardEdge,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () => showBankSheet(context, account: account),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 14, 12),
            child: Row(
              children: <Widget>[
                // Rounded icon square (matches the mockup tx rows).
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.account_balance,
                    size: 20,
                    color: cs.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        account.attributes.name,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (accountNumber?.isNotEmpty ?? false)
                        Text(
                          accountNumber!,
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  currency.fmt(balance),
                  style: Theme.of(context).textTheme.titleMedium!.copyWith(
                    color: balance < 0 ? mc.negative : mc.positive,
                    fontWeight: FontWeight.bold,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
