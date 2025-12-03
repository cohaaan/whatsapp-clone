import 'dart:async';
import 'dart:math';
import 'package:uuid/uuid.dart';

import '../../../core/network/phoenix_socket_service.dart';
import '../../../core/storage/drift_database.dart';
import '../domain/entities/message.dart';

class MessageRepository {
  final AppDatabase _db;
  final PhoenixSocketService _socket;
  final SignalSessionManager _signal;
  final ApiClient _api;

  final _uuid = const Uuid();

  MessageRepository({
    required AppDatabase db,
    required PhoenixSocketService socket,
    required SignalSessionManager signal,
    required ApiClient api,
  })  : _db = db,
        _socket = socket,
        _signal = signal,
        _api = api {
    // Listen to incoming messages
    _socket.incomingMessages.listen(_handleIncomingEnvelope);
  }

  /// Watch conversation messages (local-first, real-time updates)
  Stream<List<Message>> watchConversation(String conversationId, {int limit = 50}) {
    return _db.watchConversationMessages(conversationId, limit: limit).map(
          (dataList) => dataList.map(_messageFromData).toList(),
        );
  }

  /// Load more messages (pagination)
  Future<List<Message>> loadMoreMessages(
    String conversationId,
    DateTime before, {
    int limit = 50,
  }) async {
    final dataList = await _db.loadMoreMessages(conversationId, before, limit: limit);
    return dataList.map(_messageFromData).toList();
  }

  /// Send message (optimistic UI updates)
  Future<Message> sendMessage(String conversationId, String plaintext) async {
    final messageId = _uuid.v4();
    final clientTimestamp = DateTime.now();
    final idempotencyKey = _uuid.v4();

    // 1. Insert locally with "sending" status (optimistic UI)
    final messageData = MessageData(
      id: messageId,
      conversationId: conversationId,
      senderDeviceId: 'me', // Placeholder
      contentType: 0, // text
      plaintext: plaintext,
      clientTimestamp: clientTimestamp,
      serverTimestamp: null,
      status: MessageStatus.sending,
    );

    await _db.upsertMessage(messageData);

    // 2. Encrypt message
    try {
      final envelope = await _encryptMessage(conversationId, plaintext, messageId);

      // 3. Send via socket
      final encryptedEnvelope = EncryptedEnvelope(
        idempotencyKey: idempotencyKey,
        envelope: envelope,
        contentType: 0,
        clientTimestamp: clientTimestamp,
      );

      await _socket.sendMessage(conversationId, encryptedEnvelope);

      // 4. Update status to "sent"
      await _db.updateMessageStatus(messageId, MessageStatus.sent);

      return _messageFromData(messageData);
    } catch (e) {
      // 5. On failure, mark as failed and add to outbox for retry
      await _db.updateMessageStatus(messageId, MessageStatus.failed);
      await _addToOutbox(messageId, conversationId, plaintext);

      // Schedule retry
      _scheduleRetry(messageId, conversationId, plaintext);

      rethrow;
    }
  }

  /// Sync conversation (fetch messages from server since last sync)
  Future<void> syncConversation(String conversationId, DateTime lastSyncedAt) async {
    try {
      // Fetch server messages since last sync
      final response = await _api.get(
        '/api/conversations/$conversationId/messages',
        queryParameters: {
          'since': lastSyncedAt.toIso8601String(),
          'limit': 100,
        },
      );

      final serverMessages = response.data['messages'] as List;

      for (final serverMsg in serverMessages) {
        // Decrypt and upsert
        await _handleServerMessage(serverMsg);
      }
    } catch (e) {
      print('[MessageRepo] Sync failed: $e');
    }
  }

  /// Drain outbox (retry failed sends)
  Future<void> drainOutbox() async {
    final pendingMessages = await _db.getPendingOutboxMessages();

    for (final pending in pendingMessages) {
      if (pending.retryCount >= 5) {
        // Max retries exceeded, delete from outbox
        await _db.deleteOutboxMessage(pending.localId);
        continue;
      }

      try {
        // Retry sending
        await sendMessage(pending.conversationId, pending.plaintext);

        // Success, remove from outbox
        await _db.deleteOutboxMessage(pending.localId);
      } catch (e) {
        // Increment retry count
        await _db.incrementOutboxRetryCount(pending.localId);
      }
    }
  }

  // Private methods

  Future<void> _handleIncomingEnvelope(IncomingEnvelope envelope) async {
    try {
      // Decrypt message
      final plaintext = await _decryptMessage(envelope);

      // Upsert to local database
      final messageData = MessageData(
        id: envelope.messageId,
        conversationId: envelope.conversationId,
        senderDeviceId: envelope.senderDeviceId,
        contentType: envelope.contentType,
        plaintext: plaintext,
        clientTimestamp: envelope.clientTimestamp,
        serverTimestamp: DateTime.now(),
        status: MessageStatus.delivered,
      );

      await _db.upsertMessage(messageData);

      // Update conversation last message
      await _db.updateConversationLastMessage(
        envelope.conversationId,
        plaintext.substring(0, min(plaintext.length, 100)),
        envelope.clientTimestamp,
      );

      // Increment unread count
      await _db.incrementUnreadCount(envelope.conversationId);

      // Send "delivered" ack
      await _socket.sendAck(
        envelope.conversationId,
        envelope.messageId,
        'delivered',
      );
    } catch (e) {
      print('[MessageRepo] Failed to handle incoming message: $e');
    }
  }

  Future<void> _handleServerMessage(Map<String, dynamic> serverMsg) async {
    // Similar to _handleIncomingEnvelope but from HTTP API during sync
    // Implementation omitted for brevity
  }

  Future<Map<String, dynamic>> _encryptMessage(
    String conversationId,
    String plaintext,
    String messageId,
  ) async {
    // Get conversation type
    final conversation = await _db.getConversation(conversationId);

    if (conversation == null) {
      throw Exception('Conversation not found');
    }

    if (conversation.type == 'dm') {
      // Pairwise encryption (Double Ratchet)
      return await _encryptPairwise(conversationId, plaintext);
    } else {
      // Group encryption (Sender Keys)
      return await _encryptGroup(conversationId, plaintext);
    }
  }

  Future<Map<String, dynamic>> _encryptPairwise(
    String conversationId,
    String plaintext,
  ) async {
    // Get recipient devices
    final recipientDevices = await _getRecipientDevices(conversationId);

    if (recipientDevices.isEmpty) {
      throw Exception('No recipient devices found');
    }

    final recipientPayloads = <Map<String, dynamic>>[];

    for (final deviceId in recipientDevices) {
      // Encrypt for each device using Signal Protocol
      final ciphertext = await _signal.encrypt(deviceId, plaintext);

      recipientPayloads.add({
        'device_id': deviceId,
        'ciphertext': ciphertext,
      });
    }

    return {
      'message_type': 'pairwise',
      'recipient_payloads': recipientPayloads,
      'key_headers': [], // Populated by Signal Protocol
    };
  }

  Future<Map<String, dynamic>> _encryptGroup(
    String conversationId,
    String plaintext,
  ) async {
    // Encrypt with Sender Key
    final ciphertext = await _signal.encryptGroup(conversationId, plaintext);

    // Get all recipient devices for key headers
    final recipientDevices = await _getRecipientDevices(conversationId);
    final keyHeaders = <Map<String, dynamic>>[];

    for (final deviceId in recipientDevices) {
      // Each device gets a small key header (encrypted message key)
      final header = await _signal.createKeyHeader(conversationId, deviceId);

      keyHeaders.add({
        'device_id': deviceId,
        'header': header,
      });
    }

    return {
      'message_type': 'sender_key',
      'ciphertext': ciphertext,
      'key_headers': keyHeaders,
    };
  }

  Future<String> _decryptMessage(IncomingEnvelope envelope) async {
    final envelopeData = envelope.envelope;

    if (envelopeData['message_type'] == 'sender_key') {
      // Decrypt group message
      return await _signal.decryptGroup(
        envelope.conversationId,
        envelope.senderDeviceId,
        envelopeData['ciphertext'],
      );
    } else {
      // Decrypt pairwise message
      return await _signal.decrypt(
        envelope.senderDeviceId,
        envelopeData['ciphertext'],
      );
    }
  }

  Future<List<String>> _getRecipientDevices(String conversationId) async {
    // Query conversation members and their devices
    // Simplified: return mock data
    // In production, query from local DB or API
    return ['device-1', 'device-2'];
  }

  Future<void> _addToOutbox(String messageId, String conversationId, String plaintext) async {
    final outboxData = PendingOutboxData(
      localId: messageId,
      conversationId: conversationId,
      plaintext: plaintext,
      createdAt: DateTime.now(),
      retryCount: 0,
    );

    await _db.insertOutboxMessage(outboxData);
  }

  void _scheduleRetry(String messageId, String conversationId, String plaintext) {
    // Exponential backoff retry
    Future.delayed(const Duration(seconds: 5), () async {
      try {
        await sendMessage(conversationId, plaintext);
        await _db.deleteOutboxMessage(messageId);
      } catch (e) {
        // Will be retried on next app open or manual drain
      }
    });
  }

  Message _messageFromData(MessageData data) {
    return Message(
      id: data.id,
      conversationId: data.conversationId,
      senderDeviceId: data.senderDeviceId,
      plaintext: data.plaintext,
      contentType: data.contentType,
      clientTimestamp: data.clientTimestamp,
      serverTimestamp: data.serverTimestamp,
      status: data.status,
    );
  }
}

// Placeholder classes (to be implemented)

class SignalSessionManager {
  Future<dynamic> encrypt(String deviceId, String plaintext) async {
    // Implement using Platform Channel to native libsignal
    throw UnimplementedError();
  }

  Future<String> decrypt(String deviceId, dynamic ciphertext) async {
    throw UnimplementedError();
  }

  Future<dynamic> encryptGroup(String groupId, String plaintext) async {
    throw UnimplementedError();
  }

  Future<String> decryptGroup(String groupId, String senderDeviceId, dynamic ciphertext) async {
    throw UnimplementedError();
  }

  Future<dynamic> createKeyHeader(String groupId, String deviceId) async {
    throw UnimplementedError();
  }
}

class ApiClient {
  Future<ApiResponse> get(String path, {Map<String, dynamic>? queryParameters}) async {
    throw UnimplementedError();
  }
}

class ApiResponse {
  final dynamic data;
  ApiResponse(this.data);
}
