import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sqlcipher_flutter_libs/sqlcipher_flutter_libs.dart';

part 'drift_database.g.dart';

// Tables

@DataClassName('MessageData')
class Messages extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId => text()();
  TextColumn get senderDeviceId => text()();
  IntColumn get contentType => integer().withDefault(const Constant(0))();
  TextColumn get plaintext => text()(); // DECRYPTED content, local only
  DateTimeColumn get clientTimestamp => dateTime()();
  DateTimeColumn get serverTimestamp => dateTime().nullable()();
  IntColumn get status => intEnum<MessageStatus>()();

  @override
  Set<Column> get primaryKey => {id};
}

enum MessageStatus {
  sending,
  sent,
  delivered,
  read,
  failed,
}

@DataClassName('ConversationData')
class Conversations extends Table {
  TextColumn get id => text()();
  TextColumn get type => text()(); // 'dm' or 'group'
  TextColumn get name => text().nullable()();
  DateTimeColumn get lastMessageAt => dateTime().nullable()();
  TextColumn get lastMessagePreview => text().nullable()();
  IntColumn get unreadCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('ConversationMemberData')
class ConversationMembers extends Table {
  TextColumn get conversationId => text()();
  TextColumn get userId => text()();
  TextColumn get role => text()(); // 'admin' or 'member'
  DateTimeColumn get joinedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {conversationId, userId};
}

@DataClassName('SignalSessionData')
class SignalSessions extends Table {
  TextColumn get recipientDeviceId => text()();
  BlobColumn get sessionState => blob()(); // Serialized ratchet state
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {recipientDeviceId};
}

@DataClassName('PendingOutboxData')
class PendingOutbox extends Table {
  TextColumn get localId => text()(); // Client-generated UUID
  TextColumn get conversationId => text()();
  TextColumn get plaintext => text()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get retryCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {localId};
}

// Database

@DriftDatabase(tables: [
  Messages,
  Conversations,
  ConversationMembers,
  SignalSessions,
  PendingOutbox,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(String encryptionKey) : super(_openEncrypted(encryptionKey));

  @override
  int get schemaVersion => 1;

  static QueryExecutor _openEncrypted(String encryptionKey) {
    return LazyDatabase(() async {
      final dbFolder = await getApplicationDocumentsDirectory();
      final file = File(p.join(dbFolder.path, 'chat.db'));

      // Initialize SQLCipher
      applyWorkaroundToOpenSqlCipherOnOldAndroidVersions();

      return NativeDatabase.createInBackground(
        file,
        setup: (db) {
          // Set encryption key
          db.execute("PRAGMA key = '$encryptionKey';");

          // Performance optimizations for SQLCipher
          db.execute('PRAGMA cipher_page_size = 4096;');
          db.execute('PRAGMA kdf_iter = 64000;'); // PBKDF2 iterations
          db.execute('PRAGMA cipher_hmac_algorithm = HMAC_SHA512;');
          db.execute('PRAGMA cipher_kdf_algorithm = PBKDF2_HMAC_SHA512;');

          // General SQLite optimizations
          db.execute('PRAGMA journal_mode = WAL;'); // Write-Ahead Logging
          db.execute('PRAGMA synchronous = NORMAL;');
          db.execute('PRAGMA temp_store = MEMORY;');
          db.execute('PRAGMA mmap_size = 30000000000;');
        },
      );
    });
  }

  // Queries for Messages

  /// Watch messages for a conversation (realtime updates)
  Stream<List<MessageData>> watchConversationMessages(
    String conversationId, {
    int limit = 50,
  }) {
    return (select(messages)
          ..where((m) => m.conversationId.equals(conversationId))
          ..orderBy([(m) => OrderingTerm.desc(m.clientTimestamp)])
          ..limit(limit))
        .watch();
  }

  /// Load more messages (pagination)
  Future<List<MessageData>> loadMoreMessages(
    String conversationId,
    DateTime before, {
    int limit = 50,
  }) {
    return (select(messages)
          ..where((m) =>
              m.conversationId.equals(conversationId) &
              m.clientTimestamp.isSmallerThanValue(before))
          ..orderBy([(m) => OrderingTerm.desc(m.clientTimestamp)])
          ..limit(limit))
        .get();
  }

  /// Insert or update message
  Future<void> upsertMessage(MessageData message) {
    return into(messages).insertOnConflictUpdate(message);
  }

  /// Update message status
  Future<void> updateMessageStatus(String messageId, MessageStatus status) {
    return (update(messages)..where((m) => m.id.equals(messageId)))
        .write(MessagesCompanion(status: Value(status)));
  }

  /// Update message status and server timestamp (on successful send)
  Future<void> markMessageSent(String messageId, DateTime serverTimestamp) {
    return (update(messages)..where((m) => m.id.equals(messageId))).write(
      MessagesCompanion(
        status: const Value(MessageStatus.sent),
        serverTimestamp: Value(serverTimestamp),
      ),
    );
  }

  // Queries for Conversations

  /// Watch all conversations
  Stream<List<ConversationData>> watchConversations() {
    return (select(conversations)
          ..orderBy([(c) => OrderingTerm.desc(c.lastMessageAt)]))
        .watch();
  }

  /// Get conversation by ID
  Future<ConversationData?> getConversation(String conversationId) {
    return (select(conversations)..where((c) => c.id.equals(conversationId)))
        .getSingleOrNull();
  }

  /// Insert or update conversation
  Future<void> upsertConversation(ConversationData conversation) {
    return into(conversations).insertOnConflictUpdate(conversation);
  }

  /// Update conversation last message
  Future<void> updateConversationLastMessage(
    String conversationId,
    String preview,
    DateTime timestamp,
  ) {
    return (update(conversations)..where((c) => c.id.equals(conversationId)))
        .write(
      ConversationsCompanion(
        lastMessagePreview: Value(preview),
        lastMessageAt: Value(timestamp),
      ),
    );
  }

  /// Increment unread count
  Future<void> incrementUnreadCount(String conversationId) async {
    final conversation = await getConversation(conversationId);
    if (conversation != null) {
      await (update(conversations)..where((c) => c.id.equals(conversationId)))
          .write(
        ConversationsCompanion(
          unreadCount: Value(conversation.unreadCount + 1),
        ),
      );
    }
  }

  /// Reset unread count
  Future<void> resetUnreadCount(String conversationId) {
    return (update(conversations)..where((c) => c.id.equals(conversationId)))
        .write(
      const ConversationsCompanion(
        unreadCount: Value(0),
      ),
    );
  }

  // Queries for Signal Sessions

  /// Get Signal session
  Future<SignalSessionData?> getSignalSession(String recipientDeviceId) {
    return (select(signalSessions)
          ..where((s) => s.recipientDeviceId.equals(recipientDeviceId)))
        .getSingleOrNull();
  }

  /// Upsert Signal session
  Future<void> upsertSignalSession(SignalSessionData session) {
    return into(signalSessions).insertOnConflictUpdate(session);
  }

  /// Delete Signal session
  Future<void> deleteSignalSession(String recipientDeviceId) {
    return (delete(signalSessions)
          ..where((s) => s.recipientDeviceId.equals(recipientDeviceId)))
        .go();
  }

  // Queries for Pending Outbox

  /// Get all pending outbox messages
  Future<List<PendingOutboxData>> getPendingOutboxMessages() {
    return (select(pendingOutbox)
          ..orderBy([(p) => OrderingTerm.asc(p.createdAt)]))
        .get();
  }

  /// Insert outbox message
  Future<void> insertOutboxMessage(PendingOutboxData message) {
    return into(pendingOutbox).insert(message);
  }

  /// Delete outbox message
  Future<void> deleteOutboxMessage(String localId) {
    return (delete(pendingOutbox)..where((p) => p.localId.equals(localId)))
        .go();
  }

  /// Increment retry count
  Future<void> incrementOutboxRetryCount(String localId) async {
    final msg = await (select(pendingOutbox)
          ..where((p) => p.localId.equals(localId)))
        .getSingleOrNull();

    if (msg != null) {
      await (update(pendingOutbox)..where((p) => p.localId.equals(localId)))
          .write(
        PendingOutboxCompanion(
          retryCount: Value(msg.retryCount + 1),
        ),
      );
    }
  }

  // Database Migrations (for future schema changes)

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
      },
      onUpgrade: (Migrator m, int from, int to) async {
        // Handle migrations here
        // Example:
        // if (from < 2) {
        //   await m.addColumn(conversations, conversations.someNewColumn);
        // }
      },
    );
  }
}
