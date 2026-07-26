import 'dart:convert';

/// Encodes, finds, and renders @mentions embedded directly in a chat
/// message's plaintext.
///
/// There's no such thing as a username shared across devices in Morse
/// Messenger - a nickname is purely a local label one contact gives
/// another, and the tagged person might not even be saved as a contact on
/// every recipient's device. The only thing every device can agree on is
/// the tagged person's raw public key, so that's what actually travels on
/// the wire: a small token embedding the key is spliced directly into the
/// message text itself (which already goes through the exact same
/// sign-then-encrypt path as everything else, so this needs no changes to
/// the envelope format, storage schema, or relay at all). Each recipient
/// then renders that token using *their own* local contacts, falling back
/// to the same short-ID scheme used everywhere else in the app.
class MentionUtils {
  MentionUtils._();

  // Deliberately obscure delimiters - specific enough that no one is
  // realistically going to type them by hand in an actual message.
  static const String _open = '\u27E6M:';
  static const String _close = '\u27E7';

  static final RegExp _tokenPattern = RegExp(
    '${RegExp.escape(_open)}(.*?)${RegExp.escape(_close)}',
    dotAll: true,
  );

  /// Wraps [rawPublicKey] as an inline mention token to splice into
  /// outgoing message text. Base64-encoding the key keeps the token to a
  /// single line despite PEM keys containing embedded newlines.
  static String encodeToken(String rawPublicKey) =>
      '$_open${base64Url.encode(utf8.encode(rawPublicKey))}$_close';

  /// Every raw public key mentioned anywhere in [text], in order of
  /// appearance (duplicates included). Used to decide whether a given
  /// person was tagged - e.g. whether to fire a "you were mentioned"
  /// notification.
  static List<String> extractMentionedKeys(String text) {
    return _tokenPattern.allMatches(text).map((m) {
      return _decodeGroup(m);
    }).toList();
  }

  /// Replaces every mention token in [text] with a tappable Markdown link
  /// whose visible label is resolved *locally* via [resolveDisplayName] -
  /// so the exact same stored/received text shows each reader their own
  /// nickname for the tagged person (or their short-ID fallback), never
  /// whatever the sender happened to call them.
  static String renderMentionsAsMarkdown(
    String text,
    String Function(String rawPublicKey) resolveDisplayName,
  ) {
    return text.replaceAllMapped(_tokenPattern, (m) {
      final key = _decodeGroup(m);
      final name = resolveDisplayName(key).replaceAll(']', '');
      return '[@$name](mention:${Uri.encodeComponent(key)})';
    });
  }

  /// Same idea as [renderMentionsAsMarkdown], but for plain-text contexts
  /// that aren't Markdown-rendered - reply previews, quoted snippets,
  /// notification bodies.
  static String stripMentionsToPlainText(
    String text,
    String Function(String rawPublicKey) resolveDisplayName,
  ) {
    return text.replaceAllMapped(_tokenPattern, (m) {
      return '@${resolveDisplayName(_decodeGroup(m))}';
    });
  }

  static String _decodeGroup(Match m) =>
      utf8.decode(base64Url.decode(m.group(1)!));
}