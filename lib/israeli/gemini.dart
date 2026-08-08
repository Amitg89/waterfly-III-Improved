/// Gemini model IDs used across the app.
///
/// [geminiChatModel] backs the interactive Ask-AI panel: many short calls, so
/// the lite tier keeps token cost down. [geminiAnalysisModel] backs the budget
/// analysis, which runs about once a month and must classify salaries,
/// bonuses and recurring charges correctly — accuracy over cost there.
const String geminiChatModel = 'gemini-3.5-flash-lite';
const String geminiAnalysisModel = 'gemini-3.6-flash';

String geminiEndpoint(String model) =>
    'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent';
