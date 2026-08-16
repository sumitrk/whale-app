# Encrypt History with SQLCipher

Whale will encrypt its complete persistent History, including searchable text and stored context, with SQLCipher using a key held in macOS Keychain. This preserves SQLite FTS5/BM25 search while protecting the selected content, clipboard data, screenshots, instructions, and results that users asked Whale to retain; the accepted costs are a native dependency and loss of access to existing history if its Keychain key becomes unavailable.
