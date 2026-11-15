/// Lite mode: what is sent over a slow line is made smaller.

/// How many of the latest chat messages Lite mode sends.
const int liteKeepMessages = 8;

/// The longest answer (in tokens) Lite mode asks for.
const int liteMaxAnswerTokens = 900;

/// A long text cut down to its start and end ("…" between), so the sense is kept but fewer bytes travel.
String shorten(String text, {int max = 2500, int head = 1200, int tail = 800}) {
  if (text.length <= max) return text;
  return '${text.substring(0, head)}\n…[shortened to save data]…\n${text.substring(text.length - tail)}';
}

/// Which messages (by index) Lite mode keeps: the last [liteKeepMessages], starting with a message of the person.
List<int> liteIndexes(List<bool> isUser) {
  if (isUser.length <= liteKeepMessages) return List<int>.generate(isUser.length, (i) => i);
  var from = isUser.length - liteKeepMessages;
  while (from < isUser.length - 1 && !isUser[from]) {
    from++;
  }
  return [for (var i = from; i < isUser.length; i++) i];
}
