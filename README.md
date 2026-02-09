# Waterfly III Improved

A fork of [Waterfly III](https://github.com/dreautall/waterfly-iii) with dashboard filtering and a **Charges per card** dashboard card.

---

## Credit to the original project

**Waterfly III Improved** is based on [**Waterfly III**](https://github.com/dreautall/waterfly-iii) by [dreautall](https://github.com/dreautall).

- **Original repository:** [https://github.com/dreautall/waterfly-iii](https://github.com/dreautall/waterfly-iii)
- **License:** Same as the original project (see [LICENSE](LICENSE) in this repo).

Waterfly III is the **unofficial** Android app for [Firefly III](https://github.com/firefly-iii/firefly-iii), a free and open source personal finance manager. All credit for the app concept, architecture, and the vast majority of the codebase belongs to the original Waterfly III project and its authors.

This fork adds a set of **dashboard and filtering improvements** on top of the original app. It is not an official variant and is not affiliated with the original project.

---

## List of changes in Waterfly III Improved

The following changes were made in this fork compared to the original Waterfly III codebase.

### Dashboard filter (date range & accounts)

- **Dashboard date range:** The dashboard can be limited to a configurable time range:
  - Presets: Last 7 days, Last 30 days, Current month, Last 3 months, Last 12 months
  - **Custom range:** Start and end date pickers for any range
- **Filter dialog:** New filter icon in the app bar opens a dialog to set the date range and optionally “Select accounts.”
- **Select accounts:** Optional filter to restrict dashboard (and some cards) to selected asset/liability accounts only.
- **Persistence:** Chosen range and selected account IDs are saved and restored (e.g. via `SharedPreferences` / app settings).
- **Settings:** New enums and settings: `DashboardDateRange`, `getDashboardDateRange()`, `dashboardAccountIds`, `setDashboardDateRange()`, `setDashboardDateRangeCustom()`, `setDashboardAccountIds()`.

### New dashboard card: “Charges per card”

- **Card purpose:** Shows total **charges** (withdrawals + outbound transfers) per account for the **dashboard date range** only.
- **Data:** For each asset/liability account, transactions in the selected range are fetched and summed when the account is the source (withdrawal or transfer out). Only accounts with total charges > 0 are shown.
- **Display:**
  - **Pie chart** at the top: one slice per card; slice size = amount. Tapping a slice **hides it** from the pie (same idea as the Category Summary card). If all slices are hidden, the full pie is shown again. Chart height and card height were increased for clarity.
  - **Table:** One row per account with a short label (e.g. last 4 digits if the account name ends with 4 digits, otherwise full name) and the total amount in that account’s currency.
  - **Total row(s):** At the bottom, one or more “Total” lines: one total per currency when multiple currencies are present.
- **Localization:** New strings for title, empty state, and total label (English and Hebrew).

### Dashboard card changes

- **Removed:** The “Accounts in range” card was removed; the **Account Summary** card remains and still uses the dashboard date range and optional account filter.
- **Account Summary:** Continues to use the dashboard date range and (when set) the selected accounts; balance is taken as the chronologically last date in range.

### Robustness and UX (charts & data)

- **Chart data:** Safer handling of chart entry keys (date parsing) and values (support for both string and numeric values from the API) in overview/account chart code and in `widgets/charts.dart`.
- **Balance in tables:** Account summary and similar tables now use the **chronologically last** date in the data for the balance (instead of relying on map iteration order).
- **Empty series:** Handled without crashing when a chart series has no entries.

### Localization (l10n)

- **Hebrew:** Added Hebrew locale: `app_he.arb` and generated `app_localizations_he.dart`.
- **New keys:** All new UI strings (dashboard filter, charges-per-card card, total, etc.) were added to the ARB files and generated l10n.

### Files touched (high level)

- **Settings:** `lib/settings.dart` (dashboard range and account filter state and persistence).
- **Dashboard UI:** `lib/pages/home/main.dart` (new card, pie chart, table, total, filter key, refresh behavior), `lib/pages/home/main/dashboard.dart` (card list and titles), **new** `lib/pages/home/main/dashboard_filter.dart` (filter dialog).
- **Charts:** `lib/widgets/charts.dart` (value parsing for chart entries).
- **L10n:** `lib/l10n/app_en.arb`, `lib/l10n/app_he.arb`, and generated `lib/generated/l10n/app_localizations*.dart`.
- **Other:** `android/app/build.gradle.kts`, and any other files modified for the above (e.g. bills, transactions, transaction pages) as present in the working tree.

---

## Summary

This fork keeps full credit with the original [Waterfly III](https://github.com/dreautall/waterfly-iii) and [Firefly III](https://github.com/firefly-iii/firefly-iii) projects and adds dashboard filtering (date range + optional accounts) and a dedicated “Charges per card” dashboard card with a tappable pie chart and per-currency totals.
