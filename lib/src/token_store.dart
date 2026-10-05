/// Provides read access to authentication tokens persisted by the host app.
abstract interface class TokenStore {
  /// Reads the token stored under [key], or returns `null` when none exists.
  Future<String?> read(String key);
}
