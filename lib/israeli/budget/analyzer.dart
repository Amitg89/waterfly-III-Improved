import 'dart:convert';

import 'package:chopper/chopper.dart' show Response;
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';
import 'package:waterflyiii/generated/swagger_fireflyiii_api/firefly_iii.swagger.dart';
import 'package:waterflyiii/israeli/accounts_service.dart';
import 'package:waterflyiii/israeli/budget/models.dart';
import 'package:waterflyiii/israeli/gemini.dart';

final Logger log = Logger("Israeli.Budget.Analyzer");

/// Rolling window: the last N **complete** calendar months.
///
/// The current month is excluded on purpose — analysing on the 8th would
/// average 8 days of pay in as if it were a whole month and understate the
/// baseline. The month joins the window once it has finished.
const int budgetWindowMonths = 6;

/// Salaries normally land on the 1st-10th, but around holidays they can be
/// paid a day or two early — on the 30th/31st of the previous month. Such a
/// payment belongs to the following month. Mirrors the income chart in
/// lib/pages/home/overview.dart.
const int salaryEarlyDepositDay = 30;

const int _pageLimit = 50;
const int _maxPages = 100;

class BudgetAnalysisException implements Exception {
  BudgetAnalysisException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The window of complete months to analyse: [start] is the first day of the
/// oldest month, [endExclusive] the first day of the current month.
({DateTime start, DateTime endExclusive}) budgetWindow(DateTime now) {
  final DateTime endExclusive = DateTime(now.year, now.month, 1);
  return (
    start: DateTime(now.year, now.month - budgetWindowMonths, 1),
    endExclusive: endExclusive,
  );
}

/// The month a salary deposit belongs to, applying the early-payment rule.
DateTime salaryMonthFor(DateTime date) => date.day >= salaryEarlyDepositDay
    ? DateTime(date.year, date.month + 1, 1)
    : DateTime(date.year, date.month, 1);

/// The salary keyword matching [description], or null when it is not salary.
String? matchSalaryStream(String description, List<String> keywords) {
  final String haystack = description.toLowerCase();
  for (final String keyword in keywords) {
    if (keyword.isNotEmpty && haystack.contains(keyword.toLowerCase())) {
      return keyword;
    }
  }
  return null;
}

/// One spending transaction handed to the model for labelling.
class _SpendRow {
  const _SpendRow({
    required this.index,
    required this.date,
    required this.amount,
    required this.description,
    required this.source,
  });

  final int index;
  final DateTime date;
  final double amount;
  final String description;
  final String source;
}

/// One salary payment, before the model has judged whether it is inflated.
class _SalaryRow {
  const _SalaryRow({
    required this.index,
    required this.month,
    required this.stream,
    required this.amount,
    required this.description,
  });

  final int index;
  final DateTime month;
  final String stream;
  final double amount;
  final String description;
}

DateTime _monthStart(DateTime d) => DateTime(d.year, d.month, 1);

Future<List<TransactionRead>> _fetchAccountTransactions(
  FireflyIii api,
  String accountId,
  TransactionTypeFilter type,
  DateTime start,
  DateTime end,
) async {
  final DateFormat fmt = DateFormat('yyyy-MM-dd', 'en_US');
  final List<TransactionRead> transactions = <TransactionRead>[];
  int page = 1;
  while (page <= _maxPages) {
    final Response<TransactionArray> response = await api
        .v1AccountsIdTransactionsGet(
          id: accountId,
          type: type,
          start: fmt.format(start),
          end: fmt.format(end),
          page: page,
          limit: _pageLimit,
        );
    if (!response.isSuccessful || response.body == null) {
      log.severe("invalid transactions response", response.error);
      throw BudgetAnalysisException("Invalid API response: ${response.error}");
    }
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

/// Gathers the window: salary deposits into bank accounts (income) and
/// withdrawals from cards and bank accounts (spending).
///
/// Transfers are skipped on purpose — a transfer into a card account is the
/// bank paying the card bill, so counting it would double every card charge.
Future<
  ({
    List<_SalaryRow> salary,
    List<_SpendRow> spending,
    String currencyCode,
  })
>
_gather(
  FireflyIii api,
  DateTime now,
  List<String> salaryKeywords,
) async {
  final ({DateTime start, DateTime endExclusive}) window = budgetWindow(now);
  // Reach two days earlier so a salary paid on the 30th/31st of the month
  // before the window, which belongs to the window's first month, is fetched.
  final DateTime fetchStart = window.start.subtract(const Duration(days: 2));
  final DateTime fetchEnd = window.endExclusive.subtract(
    const Duration(days: 1),
  );

  final (List<AccountRead> banks, List<AccountRead> cards) = await (
    fetchBankAccounts(api),
    fetchCreditCardAccounts(api),
  ).wait;

  if (banks.isEmpty && cards.isEmpty) {
    throw BudgetAnalysisException('No bank or credit card accounts found');
  }

  final List<List<TransactionRead>> incomeLists = await Future.wait(
    banks.map(
      (AccountRead a) => _fetchAccountTransactions(
        api,
        a.id,
        TransactionTypeFilter.deposit,
        fetchStart,
        fetchEnd,
      ),
    ),
  );
  final List<List<TransactionRead>> spendLists = await Future.wait(
    <AccountRead>[...banks, ...cards].map(
      (AccountRead a) => _fetchAccountTransactions(
        api,
        a.id,
        TransactionTypeFilter.withdrawal,
        window.start,
        fetchEnd,
      ),
    ),
  );

  final Map<String, String> accountNames = <String, String>{
    for (final AccountRead a in <AccountRead>[...banks, ...cards])
      a.id: a.attributes.name,
  };

  String currencyCode = '';
  final List<_SalaryRow> salary = <_SalaryRow>[];

  for (final List<TransactionRead> list in incomeLists) {
    for (final TransactionRead tx in list) {
      for (final TransactionSplit split in tx.attributes.transactions) {
        if (split.type != TransactionTypeProperty.deposit) {
          continue;
        }
        // Only salary is income for budgeting purposes. Refunds, rebates and
        // peer-to-peer transfers are deliberately ignored.
        final String? stream = matchSalaryStream(
          split.description,
          salaryKeywords,
        );
        if (stream == null) {
          continue;
        }
        final DateTime month = salaryMonthFor(split.date.toLocal());
        if (month.isBefore(window.start) ||
            !month.isBefore(window.endExclusive)) {
          continue;
        }
        final double amount = double.tryParse(split.amount) ?? 0;
        if (amount <= 0) {
          continue;
        }
        currencyCode = currencyCode.isEmpty
            ? (split.currencyCode ?? '')
            : currencyCode;
        salary.add(
          _SalaryRow(
            index: salary.length,
            month: month,
            stream: stream,
            amount: amount,
            description: split.description,
          ),
        );
      }
    }
  }

  final List<_SpendRow> spending = <_SpendRow>[];
  for (final List<TransactionRead> list in spendLists) {
    for (final TransactionRead tx in list) {
      for (final TransactionSplit split in tx.attributes.transactions) {
        if (split.type != TransactionTypeProperty.withdrawal) {
          continue;
        }
        final double amount = double.tryParse(split.amount) ?? 0;
        if (amount <= 0) {
          continue;
        }
        final DateTime date = split.date.toLocal();
        if (date.isBefore(window.start) ||
            !date.isBefore(window.endExclusive)) {
          continue;
        }
        currencyCode = currencyCode.isEmpty
            ? (split.currencyCode ?? '')
            : currencyCode;
        spending.add(
          _SpendRow(
            index: spending.length,
            date: date,
            amount: amount,
            description: split.description,
            source: accountNames[split.sourceId ?? ''] ?? '',
          ),
        );
      }
    }
  }

  if (salary.isEmpty && spending.isEmpty) {
    throw BudgetAnalysisException(
      'No transactions in the last $budgetWindowMonths complete months',
    );
  }
  return (salary: salary, spending: spending, currencyCode: currencyCode);
}

/// The JSON contract we force Gemini into. Keeping the model to labels only
/// (which salary payment is inflated, which spending rows form a recurring
/// group) means every number the UI shows is computed here in Dart and stays
/// stable between runs.
const Map<String, dynamic> _schema = <String, dynamic>{
  'type': 'object',
  'properties': <String, dynamic>{
    'extraPayments': <String, dynamic>{
      'type': 'array',
      'items': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'index': <String, dynamic>{'type': 'integer'},
          'reason': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['index', 'reason'],
      },
    },
    'recurring': <String, dynamic>{
      'type': 'array',
      'items': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'name': <String, dynamic>{'type': 'string'},
          'category': <String, dynamic>{
            'type': 'string',
            'enum': <String>[
              'household',
              'insurance',
              'carAndTransport',
              'subscriptions',
              'loansAndCommitments',
              'communications',
              'healthAndEducation',
              'other',
            ],
          },
          'indexes': <String, dynamic>{
            'type': 'array',
            'items': <String, dynamic>{'type': 'integer'},
          },
        },
        'required': <String>['name', 'category', 'indexes'],
      },
    },
  },
  'required': <String>['extraPayments', 'recurring'],
};

String _buildPrompt(
  List<_SalaryRow> salary,
  List<_SpendRow> spending,
  List<String> rules,
) {
  final DateFormat dayFmt = DateFormat('yyyy-MM-dd', 'en_US');
  final DateFormat monthFmt = DateFormat('yyyy-MM', 'en_US');

  final StringBuffer salaryText = StringBuffer();
  for (final _SalaryRow r in salary) {
    salaryText.write(
      '${r.index}|${monthFmt.format(r.month)}|${r.stream}|'
      '${r.amount.toStringAsFixed(2)}|${r.description}\n',
    );
  }
  final StringBuffer spendText = StringBuffer();
  for (final _SpendRow r in spending) {
    spendText.write(
      '${r.index}|${dayFmt.format(r.date)}|${r.amount.toStringAsFixed(2)}|'
      '${r.description}|${r.source}\n',
    );
  }

  final String rulesBlock = rules.isEmpty
      ? ''
      : 'The user has given these standing corrections. They override your '
            'own judgement and apply to every run:\n'
            '${rules.map((String r) => '- $r').join('\n')}\n\n';

  return 'You classify a household\'s salary and card transactions so a '
      'budgeting app can work out their regular monthly pay and their fixed '
      'monthly costs. Do not do arithmetic; only label rows by index.\n\n'
      '$rulesBlock'
      'SALARY payments, "index|month|earner|amount|description". Each earner '
      'is a separate salary stream, and bonuses arrive inside the salary '
      'payment rather than separately:\n$salaryText\n'
      'Task 1 — extraPayments: within EACH earner\'s own stream, list the '
      'indexes of payments that are inflated by extra pay on top of regular '
      'salary. Judge each earner only against their own other months, never '
      'against the other earner.\n'
      'Israeli payslips bundle several annual or occasional payments into the '
      'salary transfer. Treat any of these as extra pay: הבראה (recuperation '
      'allowance, usually paid once a year in summer), דמי הבראה, מענק / bonus '
      'of any kind, 13th salary, פדיון חופשה (holiday pay-out), הפרשים / '
      'back-pay, ביגוד (clothing allowance), and yearly or holiday grants.\n'
      'These are often only 15-30%% above the earner\'s usual amount, so do '
      'NOT look only for dramatic outliers — a payment moderately but clearly '
      'above that earner\'s normal range in a month where such an allowance is '
      'typically paid should be flagged. Ordinary month-to-month variation '
      'from overtime or travel pay is NOT extra pay. If an earner\'s payments '
      'are all about the same size, list none of them. Give a short reason for '
      'each.\n\n'
      'SPENDING, "index|date|amount|description|account":\n$spendText\n'
      'Task 2 — recurring: group SPENDING rows that repeat every month at a '
      'similar amount (insurance premiums, utilities, municipal tax, rent or '
      'mortgage, loan repayments, phone and internet, streaming and other '
      'subscriptions, gym, regular school or health payments). Give each group '
      'a short human name and one category. Put water, electricity, gas and '
      'municipal tax under "household". Exclude one-off purchases, groceries, '
      'restaurants, fuel and shopping — variable spending is not a fixed cost. '
      'A group needs at least 3 of the $budgetWindowMonths months to count.';
}

Future<Map<String, dynamic>> _callGemini(String prompt, String apiKey) async {
  final http.Response response = await http.post(
    Uri.parse(geminiEndpoint(geminiAnalysisModel)),
    headers: <String, String>{
      'Content-Type': 'application/json',
      'x-goog-api-key': apiKey,
    },
    body: jsonEncode(<String, dynamic>{
      'contents': <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 'user',
          'parts': <Map<String, dynamic>>[
            <String, dynamic>{'text': prompt},
          ],
        },
      ],
      'generationConfig': <String, dynamic>{
        'responseMimeType': 'application/json',
        'responseSchema': _schema,
      },
    }),
  );

  if (response.statusCode != 200) {
    String message = 'Gemini API error: ${response.statusCode}';
    try {
      final Map<String, dynamic> body =
          jsonDecode(response.body) as Map<String, dynamic>;
      final String? detail =
          (body['error'] as Map<String, dynamic>?)?['message'] as String?;
      if (detail != null && detail.isNotEmpty) {
        message = '$message — $detail';
      }
    } on FormatException {
      // Body was not JSON; the status-code message is all we have.
    }
    throw BudgetAnalysisException(message);
  }

  final Map<String, dynamic> body =
      jsonDecode(response.body) as Map<String, dynamic>;
  final List<dynamic>? candidates = body['candidates'] as List<dynamic>?;
  if (candidates == null || candidates.isEmpty) {
    throw BudgetAnalysisException('Gemini returned no result');
  }
  final List<dynamic>? parts =
      ((candidates.first as Map<String, dynamic>)['content']
              as Map<String, dynamic>?)?['parts']
          as List<dynamic>?;
  final String? text = parts == null || parts.isEmpty
      ? null
      : (parts.first as Map<String, dynamic>)['text'] as String?;
  if (text == null || text.isEmpty) {
    throw BudgetAnalysisException('Gemini returned an empty result');
  }
  try {
    return jsonDecode(text) as Map<String, dynamic>;
  } on FormatException {
    throw BudgetAnalysisException('Gemini returned malformed JSON');
  }
}

/// Runs a full analysis: gather the complete-month window, have Gemini label
/// it, then compute every figure locally.
Future<BudgetAnalysis> runBudgetAnalysis({
  required FireflyIii api,
  required String geminiApiKey,
  required List<String> salaryKeywords,
  required List<String> rules,
  DateTime? now,
}) async {
  final DateTime at = now ?? DateTime.now();
  if (salaryKeywords.isEmpty) {
    throw BudgetAnalysisException(
      'No salary keywords configured — set them in Settings',
    );
  }

  final ({
    List<_SalaryRow> salary,
    List<_SpendRow> spending,
    String currencyCode,
  })
  gathered = await _gather(api, at, salaryKeywords);

  if (gathered.salary.isEmpty) {
    throw BudgetAnalysisException(
      'No salary deposits matched your salary keywords',
    );
  }

  final Map<String, dynamic> labels = await _callGemini(
    _buildPrompt(gathered.salary, gathered.spending, rules),
    geminiApiKey,
  );

  final Map<int, String> extraReasons = <int, String>{};
  for (final dynamic entry
      in labels['extraPayments'] as List<dynamic>? ?? <dynamic>[]) {
    final Map<String, dynamic> e = entry as Map<String, dynamic>;
    final int? index = (e['index'] as num?)?.toInt();
    if (index != null) {
      extraReasons[index] = e['reason'] as String? ?? '';
    }
  }

  final List<SalaryEntry> salary = gathered.salary
      .map(
        (_SalaryRow row) => SalaryEntry(
          month: row.month,
          stream: row.stream,
          amount: row.amount,
          isExtra: extraReasons.containsKey(row.index),
          note: extraReasons[row.index] ?? '',
        ),
      )
      .toList();

  final Map<int, _SpendRow> spendByIndex = <int, _SpendRow>{
    for (final _SpendRow r in gathered.spending) r.index: r,
  };

  final List<RecurringCharge> charges = <RecurringCharge>[];
  for (final dynamic entry
      in labels['recurring'] as List<dynamic>? ?? <dynamic>[]) {
    final Map<String, dynamic> group = entry as Map<String, dynamic>;
    final List<_SpendRow> rows =
        (group['indexes'] as List<dynamic>? ?? <dynamic>[])
            .map((dynamic i) => spendByIndex[(i as num).toInt()])
            .whereType<_SpendRow>()
            .toList();
    if (rows.isEmpty) {
      continue;
    }
    final Set<DateTime> monthsSeen = rows
        .map((_SpendRow r) => _monthStart(r.date))
        .toSet();
    final double total = rows.fold<double>(
      0,
      (double sum, _SpendRow r) => sum + r.amount,
    );
    charges.add(
      RecurringCharge(
        name: group['name'] as String? ?? '',
        category: BudgetCategory.parse(group['category'] as String?),
        // Per-month cost: total spend spread over the months it appeared in,
        // so a charge billed twice in one month is not counted as monthly.
        monthlyAmount: total / monthsSeen.length,
        monthsSeen: monthsSeen.length,
        monthsInWindow: budgetWindowMonths,
        source: rows.first.source,
      ),
    );
  }

  return BudgetAnalysis(
    analyzedAt: at,
    currencyCode: gathered.currencyCode,
    windowMonths: budgetWindowMonths,
    salary: salary,
    charges: charges,
  );
}
