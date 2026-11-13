/// Keys and tokens must never reach the log or a copied report.
library;

String redact(String s) => s
    .replaceAll(RegExp(r'AIza[0-9A-Za-z_\-]{20,}'), 'AIza…')
    .replaceAll(RegExp(r'sk-or-[A-Za-z0-9_\-]{10,}'), 'sk-or-…')
    .replaceAll(RegExp(r'gsk_[A-Za-z0-9]{10,}'), 'gsk_…')
    .replaceAll(RegExp(r'github_pat_[A-Za-z0-9_]{20,}'), 'github_pat_…')
    .replaceAll(RegExp(r'gh[pousr]_[A-Za-z0-9]{20,}'), 'gh…')
    .replaceAll(RegExp(r'Bearer\s+[A-Za-z0-9._\-]{10,}'), 'Bearer …')
    .replaceAllMapped(RegExp(r'(key|token|secret)=([^&\s]{8,})', caseSensitive: false), (m) => '${m[1]}=…');
