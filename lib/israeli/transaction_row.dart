import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:waterflyiii/auth.dart';
import 'package:waterflyiii/extensions.dart';
import 'package:waterflyiii/generated/l10n/app_localizations.dart';
import 'package:waterflyiii/generated/swagger_fireflyiii_api/firefly_iii.swagger.dart';

/// The currency of an account, falling back to the instance default.
CurrencyRead currencyFromAccount(BuildContext context, AccountRead account) {
  final CurrencyRead currency = CurrencyRead(
    id: account.attributes.currencyId ?? "0",
    type: "currencies",
    attributes: CurrencyProperties(
      code: account.attributes.currencyCode ?? "",
      name: "",
      symbol: account.attributes.currencySymbol ?? "",
      decimalPlaces: account.attributes.currencyDecimalPlaces,
    ),
  );
  if (currency.id == "0") {
    return context.read<FireflyService>().defaultCurrency;
  }
  return currency;
}

/// The currency of a transaction split, falling back to the instance default.
CurrencyRead currencyFromSplit(BuildContext context, TransactionSplit split) {
  final CurrencyRead currency = CurrencyRead(
    id: split.currencyId ?? "0",
    type: "currencies",
    attributes: CurrencyProperties(
      code: split.currencyCode ?? "",
      name: split.currencyName ?? "",
      symbol: split.currencySymbol ?? "",
      decimalPlaces: split.currencyDecimalPlaces,
    ),
  );
  if (currency.id == "0") {
    return context.read<FireflyService>().defaultCurrency;
  }
  return currency;
}

/// A compact transaction list row used by the Banks & Cards detail pages:
/// description, (purchase) date, amount signed & colored by type, and an
/// optional "Billed [processDate]" caption when the billing date differs
/// from the purchase date.
Widget israeliTransactionRow(
  BuildContext context,
  TransactionRead item, {
  bool showBilledCaption = false,
}) {
  final List<TransactionSplit> transactions = item.attributes.transactions;
  if (transactions.isEmpty) {
    return const SizedBox.shrink();
  }
  final TransactionSplit first = transactions.first;

  late String title;
  if (item.attributes.groupTitle?.isNotEmpty ?? false) {
    title = item.attributes.groupTitle!;
  } else {
    title = first.description;
  }

  double amount = 0;
  for (TransactionSplit split in transactions) {
    amount += double.tryParse(split.amount) ?? 0;
  }
  if (first.type == TransactionTypeProperty.withdrawal) {
    amount *= -1;
  }
  final CurrencyRead currency = currencyFromSplit(context, first);

  final DateTime date = first.date.toLocal();
  final List<String> subtitleLines = <String>[DateFormat.yMMMd().format(date)];
  if (showBilledCaption && first.processDate != null) {
    final DateTime billed = first.processDate!.toLocal();
    final bool differs =
        billed.year != date.year ||
        billed.month != date.month ||
        billed.day != date.day;
    if (differs) {
      subtitleLines.add(
        S.of(context).cardsBilledOn(DateFormat.yMd().format(billed)),
      );
    }
  }

  return ListTile(
    leading: CircleAvatar(
      foregroundColor: Colors.white,
      backgroundColor: first.type.color,
      child: Icon(first.type.icon),
    ),
    title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      subtitleLines.join("\n"),
      maxLines: subtitleLines.length,
      style: Theme.of(context).textTheme.bodySmall,
    ),
    isThreeLine: subtitleLines.length > 1,
    trailing: Text(
      currency.fmt(amount),
      style: Theme.of(context).textTheme.titleMedium!.copyWith(
        color: first.type.color,
        fontWeight: FontWeight.bold,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
    ),
  );
}
