import 'package:chopper/chopper.dart' show Response;
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:waterflyiii/generated/swagger_fireflyiii_api/firefly_iii.swagger.dart';

/// Data helpers for the Israeli banking views (Banks & Cards tabs).
///
/// Domain background: Israeli credit cards bill monthly. The billing cycle
/// runs from the cycle day (default: 10th) of one month up to the day before
/// the cycle day of the next month, and the accumulated total is charged to
/// the bank account on the next cycle day. Every imported card transaction
/// carries `process_date` = its billing date.

final Logger log = Logger("Israeli.AccountsService");

const int _pageLimit = 50;

// Safety net so a server bug can never make us loop forever.
const int _maxPages = 100;

void _throwIfInvalid(Response<dynamic> response) {
  if (response.isSuccessful && response.body != null) {
    return;
  }
  log.severe("Invalid API response", response.error);
  throw Exception("Invalid API response: ${response.error}");
}

Future<List<AccountRead>> _fetchAssetAccountsByRole(
  FireflyIii api,
  AccountRoleProperty role,
) async {
  final List<AccountRead> accounts = <AccountRead>[];
  int page = 1;
  while (page <= _maxPages) {
    final Response<AccountArray> response = await api.v1AccountsGet(
      type: AccountTypeFilter.asset,
      page: page,
    );
    _throwIfInvalid(response);
    final List<AccountRead> data = response.body!.data;
    accounts.addAll(
      data.where((AccountRead a) => a.attributes.accountRole == role),
    );
    final int? totalPages = response.body!.meta.pagination?.totalPages;
    if (data.length < _pageLimit ||
        (totalPages != null && page >= totalPages)) {
      break;
    }
    page++;
  }
  return accounts;
}

/// Bank accounts: Firefly asset accounts with account_role == defaultAsset.
Future<List<AccountRead>> fetchBankAccounts(FireflyIii api) =>
    _fetchAssetAccountsByRole(api, AccountRoleProperty.defaultasset);

/// Credit cards: Firefly asset accounts with account_role == ccAsset.
Future<List<AccountRead>> fetchCreditCardAccounts(FireflyIii api) =>
    _fetchAssetAccountsByRole(api, AccountRoleProperty.ccasset);

/// Returns the previous ([start]) and upcoming ([end]) charge dates for the
/// billing cycle that `now` falls into.
///
/// The upcoming charge date is the next occurrence of [cycleDay]:
/// - if now.day < cycleDay, it is cycleDay of the current month;
/// - if now.day >= cycleDay (including the cycle day itself, when the charge
///   has already happened), it is cycleDay of the next month.
///
/// The "upcoming charge" window is (start, end]: process_date strictly after
/// the previous charge date and up to and including the upcoming one.
({DateTime start, DateTime end}) currentCycle(DateTime now, int cycleDay) {
  assert(cycleDay >= 1 && cycleDay <= 28);
  if (now.day < cycleDay) {
    return (
      // Dart normalizes month 0 to December of the previous year.
      start: DateTime(now.year, now.month - 1, cycleDay),
      end: DateTime(now.year, now.month, cycleDay),
    );
  }
  return (
    start: DateTime(now.year, now.month, cycleDay),
    // Dart normalizes month 13 to January of the next year.
    end: DateTime(now.year, now.month + 1, cycleDay),
  );
}

/// True if [processDate] falls inside the (prevCharge, nextCharge] window
/// (compared by calendar date, in local time).
///
/// A null [processDate] is treated as inside the window: the server-side
/// search already filtered on process_date, so a transaction without a
/// serialized process_date field is trusted to match the server filter.
bool _inCycleWindow(
  DateTime? processDate,
  DateTime prevCharge,
  DateTime nextCharge,
) {
  if (processDate == null) {
    return true;
  }
  final DateTime local = processDate.toLocal();
  final DateTime day = DateTime(local.year, local.month, local.day);
  final DateTime start = DateTime(
    prevCharge.year,
    prevCharge.month,
    prevCharge.day,
  );
  final DateTime end = DateTime(
    nextCharge.year,
    nextCharge.month,
    nextCharge.day,
  );
  return day.isAfter(start) && !day.isAfter(end);
}

bool _isCardCycleType(TransactionTypeProperty? type) =>
    type == TransactionTypeProperty.withdrawal ||
    type == TransactionTypeProperty.deposit;

/// Fetches all transactions on [accountId] whose process_date falls in the
/// (prevCharge, nextCharge] window, using the Firefly search API.
///
/// Query semantics: Firefly's `process_date_after` / `process_date_before`
/// operators have had both inclusive (>=/<=) and exclusive (>/<) semantics
/// across versions. To be correct under either interpretation we query
/// `process_date_after:"<prevCharge>"` and
/// `process_date_before:"<nextCharge + 1 day>"`, which is a superset of the
/// desired (prevCharge, nextCharge] window in both cases, and then trim
/// precisely client-side via [_inCycleWindow].
Future<List<TransactionRead>> _searchProcessDateWindow(
  FireflyIii api,
  String accountId,
  DateTime prevCharge,
  DateTime nextCharge,
) async {
  final DateFormat fmt = DateFormat('yyyy-MM-dd', 'en_US');
  // Day arithmetic via the constructor is DST-safe (Dart normalizes day 32).
  final DateTime dayAfterNextCharge = DateTime(
    nextCharge.year,
    nextCharge.month,
    nextCharge.day + 1,
  );
  final String query =
      'account_id:$accountId '
      'process_date_after:"${fmt.format(prevCharge)}" '
      'process_date_before:"${fmt.format(dayAfterNextCharge)}"';
  log.fine(() => "searching transactions: $query");

  final List<TransactionRead> transactions = <TransactionRead>[];
  int page = 1;
  while (page <= _maxPages) {
    final Response<TransactionArray> response = await api
        .v1SearchTransactionsGet(query: query, page: page, limit: _pageLimit);
    _throwIfInvalid(response);
    final List<TransactionRead> data = response.body!.data;
    transactions.addAll(data);
    final int? totalPages = response.body!.meta.pagination?.totalPages;
    if (data.length < _pageLimit ||
        (totalPages != null && page >= totalPages)) {
      break;
    }
    page++;
  }
  return transactions;
}

/// The upcoming charge for a credit card account: the sum over all
/// transactions on the card whose process_date (billing date) lies in the
/// (prevCharge, nextCharge] window, counting withdrawals as positive and
/// deposits (refunds) as negative. Transfers are excluded — a transfer to
/// the card is the bank paying the card bill, not consumption.
Future<double> fetchUpcomingCharge(
  FireflyIii api,
  String accountId,
  DateTime prevCharge,
  DateTime nextCharge,
) async {
  final List<TransactionRead> transactions = await _searchProcessDateWindow(
    api,
    accountId,
    prevCharge,
    nextCharge,
  );
  double sum = 0;
  for (final TransactionRead transaction in transactions) {
    for (final TransactionSplit split in transaction.attributes.transactions) {
      if (!_isCardCycleType(split.type) ||
          !_inCycleWindow(split.processDate, prevCharge, nextCharge)) {
        continue;
      }
      final double amount = double.tryParse(split.amount) ?? 0;
      sum +=
          split.type == TransactionTypeProperty.withdrawal ? amount : -amount;
    }
  }
  return sum;
}

/// The transactions making up a card cycle: withdrawals and deposits (no
/// transfers) on [accountId] with process_date in (prevCharge, nextCharge],
/// sorted by (purchase) date descending.
Future<List<TransactionRead>> fetchCycleTransactions(
  FireflyIii api,
  String accountId,
  DateTime prevCharge,
  DateTime nextCharge,
) async {
  final List<TransactionRead> transactions = await _searchProcessDateWindow(
    api,
    accountId,
    prevCharge,
    nextCharge,
  );
  final List<TransactionRead> filtered =
      transactions.where((TransactionRead transaction) {
        final List<TransactionSplit> splits =
            transaction.attributes.transactions;
        if (splits.isEmpty) {
          return false;
        }
        return _isCardCycleType(splits.first.type) &&
            _inCycleWindow(splits.first.processDate, prevCharge, nextCharge);
      }).toList();
  filtered.sort(
    (TransactionRead a, TransactionRead b) => b
        .attributes
        .transactions
        .first
        .date
        .compareTo(a.attributes.transactions.first.date),
  );
  return filtered;
}
