import 'dart:async';
import 'dart:math';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:rxdart/rxdart.dart';

enum ConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
}

class IncomingEnvelope {
  final String messageId;
  final String conversationId;
  final String senderDeviceId;
  final Map<String, dynamic> envelope;
  final int contentType;
  final DateTime clientTimestamp;

  IncomingEnvelope({
    required this.messageId,
    required this.conversationId,
    required this.senderDeviceId,
    required this.envelope,
    required this.contentType,
    required this.clientTimestamp,
  });

  factory IncomingEnvelope.fromJson(Map<String, dynamic> json) {
    return IncomingEnvelope(
      messageId: json['message_id'],
      conversationId: json['conversation_id'],
      senderDeviceId: json['sender_device_id'],
      envelope: json['envelope'],
      contentType: json['content_type'] ?? 0,
      clientTimestamp: DateTime.parse(json['client_timestamp']),
    );
  }
}

class EncryptedEnvelope {
  final String idempotencyKey;
  final Map<String, dynamic> envelope;
  final int contentType;
  final DateTime clientTimestamp;

  EncryptedEnvelope({
    required this.idempotencyKey,
    required this.envelope,
    required this.contentType,
    required this.clientTimestamp,
  });

  Map<String, dynamic> toJson() {
    return {
      'idempotency_key': idempotencyKey,
      'envelope': envelope,
      'content_type': contentType,
      'client_timestamp': clientTimestamp.toIso8601String(),
    };
  }
}

class PhoenixSocketService {
  final String baseUrl;
  final Duration heartbeatInterval;

  PhoenixSocket? _socket;
  final Map<String, PhoenixChannel> _channels = {};
  final _connectionState = BehaviorSubject<ConnectionState>.seeded(ConnectionState.disconnected);
  final _incomingMessages = PublishSubject<IncomingEnvelope>();

  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _shouldReconnect = true;

  // Exponential backoff: 1s → 2s → 4s → 8s → 16s → max 30s
  static const _baseBackoffSeconds = 1;
  static const _maxBackoffSeconds = 30;

  PhoenixSocketService({
    required this.baseUrl,
    this.heartbeatInterval = const Duration(seconds: 30),
  });

  Stream<ConnectionState> get connectionState => _connectionState.stream;
  Stream<IncomingEnvelope> get incomingMessages => _incomingMessages.stream;

  Future<void> connect(String token, String deviceId) async {
    if (_socket != null && _connectionState.value == ConnectionState.connected) {
      return; // Already connected
    }

    _shouldReconnect = true;
    await _initializeSocket(token, deviceId);
  }

  Future<void> disconnect() async {
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    // Leave all channels
    for (final channel in _channels.values) {
      await channel.leave();
    }
    _channels.clear();

    await _socket?.disconnect();
    _socket = null;

    _connectionState.add(ConnectionState.disconnected);
  }

  Future<PhoenixChannel> joinConversation(String conversationId) async {
    final channelKey = 'conversation:$conversationId';

    if (_channels.containsKey(channelKey)) {
      return _channels[channelKey]!;
    }

    if (_socket == null) {
      throw Exception('Socket not connected. Call connect() first.');
    }

    final channel = _socket!.addChannel(topic: channelKey);

    // Set up message handlers
    channel.on('msg:new', (payload) {
      _handleIncomingMessage(payload?.response);
    });

    channel.on('msg:ack', (payload) {
      // Handle delivery/read receipts
      _handleAck(payload?.response);
    });

    channel.on('typing', (payload) {
      // Handle typing indicator
      _handleTyping(payload?.response);
    });

    channel.on('typing:stop', (payload) {
      // Handle stop typing
      _handleTypingStop(payload?.response);
    });

    channel.on('presence_state', (payload) {
      // Handle initial presence state
      _handlePresenceState(payload?.response);
    });

    channel.on('presence_diff', (payload) {
      // Handle presence changes
      _handlePresenceDiff(payload?.response);
    });

    // Join the channel
    final push = channel.join();
    await push.future;

    if (push.response?.status == 'ok') {
      _channels[channelKey] = channel;
      return channel;
    } else {
      throw Exception('Failed to join conversation: ${push.response?.response}');
    }
  }

  Future<void> leaveConversation(String conversationId) async {
    final channelKey = 'conversation:$conversationId';
    final channel = _channels.remove(channelKey);

    if (channel != null) {
      await channel.leave();
    }
  }

  Future<void> sendMessage(String conversationId, EncryptedEnvelope envelope) async {
    final channelKey = 'conversation:$conversationId';
    final channel = _channels[channelKey];

    if (channel == null) {
      throw Exception('Not joined to conversation: $conversationId');
    }

    final push = channel.push('msg:send', envelope.toJson());

    try {
      await push.future.timeout(const Duration(seconds: 10));

      if (push.response?.status != 'ok') {
        throw Exception('Send failed: ${push.response?.response}');
      }
    } catch (e) {
      throw Exception('Send timeout or error: $e');
    }
  }

  Future<void> sendAck(String conversationId, String messageId, String status) async {
    final channelKey = 'conversation:$conversationId';
    final channel = _channels[channelKey];

    if (channel == null) {
      return; // Silently fail if not in channel
    }

    channel.push('msg:ack', {
      'message_id': messageId,
      'status': status,
    });
  }

  Future<void> sendTyping(String conversationId) async {
    final channelKey = 'conversation:$conversationId';
    final channel = _channels[channelKey];

    if (channel != null) {
      channel.push('typing', {});
    }
  }

  Future<void> sendTypingStop(String conversationId) async {
    final channelKey = 'conversation:$conversationId';
    final channel = _channels[channelKey];

    if (channel != null) {
      channel.push('typing:stop', {});
    }
  }

  void dispose() {
    _reconnectTimer?.cancel();
    _connectionState.close();
    _incomingMessages.close();
  }

  // Private methods

  Future<void> _initializeSocket(String token, String deviceId) async {
    _connectionState.add(
      _reconnectAttempts > 0 ? ConnectionState.reconnecting : ConnectionState.connecting,
    );

    final socketUrl = baseUrl.replaceAll('http', 'ws');

    _socket = PhoenixSocket(
      '$socketUrl/socket',
      socketOptions: PhoenixSocketOptions(
        params: {
          'token': token,
        },
        timeout: const Duration(seconds: 10),
      ),
    );

    // Set up connection state handlers
    _socket!.onOpen(() {
      print('[Socket] Connected');
      _reconnectAttempts = 0;
      _connectionState.add(ConnectionState.connected);

      // Auto-rejoin channels
      _rejoinChannels();
    });

    _socket!.onClose((_) {
      print('[Socket] Closed');
      _connectionState.add(ConnectionState.disconnected);

      if (_shouldReconnect) {
        _scheduleReconnect();
      }
    });

    _socket!.onError((error) {
      print('[Socket] Error: $error');

      if (_shouldReconnect) {
        _scheduleReconnect();
      }
    });

    // Connect
    try {
      _socket!.connect();
    } catch (e) {
      print('[Socket] Connection error: $e');

      if (_shouldReconnect) {
        _scheduleReconnect();
      }
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();

    // Calculate backoff with jitter
    final backoffSeconds = min(
      _baseBackoffSeconds * pow(2, _reconnectAttempts),
      _maxBackoffSeconds,
    ).toInt();

    // Add jitter (0-1 second)
    final jitter = Random().nextInt(1000);
    final delayMs = (backoffSeconds * 1000) + jitter;

    print('[Socket] Reconnecting in ${delayMs}ms (attempt ${_reconnectAttempts + 1})');

    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _reconnectAttempts++;
      _initializeSocket('', ''); // Token will be refreshed
    });
  }

  Future<void> _rejoinChannels() async {
    final channelsCopy = Map<String, PhoenixChannel>.from(_channels);
    _channels.clear();

    for (final entry in channelsCopy.entries) {
      final topic = entry.key;

      if (topic.startsWith('conversation:')) {
        final conversationId = topic.split(':')[1];

        try {
          await joinConversation(conversationId);
        } catch (e) {
          print('[Socket] Failed to rejoin $conversationId: $e');
        }
      }
    }
  }

  void _handleIncomingMessage(Map<String, dynamic>? payload) {
    if (payload == null) return;

    try {
      final envelope = IncomingEnvelope.fromJson(payload);
      _incomingMessages.add(envelope);
    } catch (e) {
      print('[Socket] Failed to parse incoming message: $e');
    }
  }

  void _handleAck(Map<String, dynamic>? payload) {
    // Emit to acknowledgment stream (implement if needed)
    print('[Socket] Ack received: $payload');
  }

  void _handleTyping(Map<String, dynamic>? payload) {
    // Emit to typing indicator stream (implement if needed)
    print('[Socket] Typing: $payload');
  }

  void _handleTypingStop(Map<String, dynamic>? payload) {
    print('[Socket] Typing stopped: $payload');
  }

  void _handlePresenceState(Map<String, dynamic>? payload) {
    print('[Socket] Presence state: $payload');
  }

  void _handlePresenceDiff(Map<String, dynamic>? payload) {
    print('[Socket] Presence diff: $payload');
  }
}
