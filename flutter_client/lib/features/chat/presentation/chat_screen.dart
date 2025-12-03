import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:math' as math;

import '../../../core/storage/drift_database.dart';
import '../data/message_repository.dart';
import '../domain/entities/message.dart';
import 'widgets/message_bubble.dart';
import 'widgets/message_input.dart';

// Providers
final messageRepositoryProvider = Provider<MessageRepository>((ref) {
  throw UnimplementedError('Must be overridden');
});

final conversationMessagesProvider =
    StreamProvider.family<List<Message>, String>((ref, conversationId) {
  final repo = ref.watch(messageRepositoryProvider);
  return repo.watchConversation(conversationId);
});

final chatScreenControllerProvider =
    StateNotifierProvider.family<ChatScreenController, ChatScreenState, String>(
  (ref, conversationId) {
    return ChatScreenController(
      conversationId: conversationId,
      repository: ref.watch(messageRepositoryProvider),
    );
  },
);

// State
class ChatScreenState {
  final bool isLoading;
  final bool hasMore;
  final bool showScrollToBottom;
  final String? error;

  ChatScreenState({
    this.isLoading = false,
    this.hasMore = true,
    this.showScrollToBottom = false,
    this.error,
  });

  ChatScreenState copyWith({
    bool? isLoading,
    bool? hasMore,
    bool? showScrollToBottom,
    String? error,
  }) {
    return ChatScreenState(
      isLoading: isLoading ?? this.isLoading,
      hasMore: hasMore ?? this.hasMore,
      showScrollToBottom: showScrollToBottom ?? this.showScrollToBottom,
      error: error ?? this.error,
    );
  }
}

// Controller
class ChatScreenController extends StateNotifier<ChatScreenState> {
  final String conversationId;
  final MessageRepository repository;

  ChatScreenController({
    required this.conversationId,
    required this.repository,
  }) : super(ChatScreenState());

  Future<void> loadMoreMessages(DateTime? oldestTimestamp) async {
    if (state.isLoading || !state.hasMore) return;

    state = state.copyWith(isLoading: true);

    try {
      final messages = await repository.loadMoreMessages(
        conversationId,
        oldestTimestamp ?? DateTime.now(),
        limit: 50,
      );

      if (messages.isEmpty || messages.length < 50) {
        state = state.copyWith(hasMore: false);
      }

      state = state.copyWith(isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load messages: $e',
      );
    }
  }

  void setShowScrollToBottom(bool show) {
    state = state.copyWith(showScrollToBottom: show);
  }

  Future<void> sendMessage(String text) async {
    try {
      await repository.sendMessage(conversationId, text);
    } catch (e) {
      state = state.copyWith(error: 'Failed to send message: $e');
    }
  }
}

// Screen
class ChatScreen extends ConsumerStatefulWidget {
  final String conversationId;
  final String conversationName;

  const ChatScreen({
    Key? key,
    required this.conversationId,
    required this.conversationName,
  }) : super(key: key);

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();

  bool _isAtBottom = true;
  DateTime? _oldestMessageTimestamp;

  @override
  void initState() {
    super.initState();

    _scrollController.addListener(_onScroll);

    // Auto-scroll to bottom on new messages
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  void _onScroll() {
    final controller = ref.read(chatScreenControllerProvider(widget.conversationId).notifier);

    // Check if scrolled up > 2 screens from bottom
    final showFab = _scrollController.position.pixels <
        _scrollController.position.maxScrollExtent - (MediaQuery.of(context).size.height * 2);

    if (showFab != _isAtBottom) {
      _isAtBottom = !showFab;
      controller.setShowScrollToBottom(showFab);
    }

    // Pull-to-load-more at top
    if (_scrollController.position.pixels <= 100 && !_scrollController.position.outOfRange) {
      controller.loadMoreMessages(_oldestMessageTimestamp);
    }

    // Mark messages as read when scrolled into view (simplified)
    // In production, track visible messages and send read receipts
  }

  void _scrollToBottom() {
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final messagesAsync = ref.watch(conversationMessagesProvider(widget.conversationId));
    final screenState = ref.watch(chatScreenControllerProvider(widget.conversationId));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.conversationName),
        actions: [
          IconButton(
            icon: const Icon(Icons.videocam),
            onPressed: () {
              // Video call
            },
          ),
          IconButton(
            icon: const Icon(Icons.call),
            onPressed: () {
              // Audio call
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Messages list
          Expanded(
            child: messagesAsync.when(
              data: (messages) {
                if (messages.isEmpty) {
                  return const Center(
                    child: Text('No messages yet. Say hi!'),
                  );
                }

                // Update oldest timestamp for pagination
                if (messages.isNotEmpty) {
                  _oldestMessageTimestamp = messages.last.clientTimestamp;
                }

                return Stack(
                  children: [
                    // Message list with performance optimizations
                    CustomScrollView(
                      controller: _scrollController,
                      reverse: true, // Start from bottom
                      cacheExtent: 1000, // Preload messages above/below
                      slivers: [
                        SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              if (index == messages.length) {
                                // Loading indicator at top
                                return screenState.isLoading
                                    ? const Padding(
                                        padding: EdgeInsets.all(16.0),
                                        child: Center(
                                          child: CircularProgressIndicator(),
                                        ),
                                      )
                                    : const SizedBox.shrink();
                              }

                              // Reverse index since list is reversed
                              final message = messages[messages.length - 1 - index];

                              return MessageBubble(
                                key: ValueKey(message.id),
                                message: message,
                                showSenderName: false, // For DM
                                onLongPress: () => _onMessageLongPress(message),
                              );
                            },
                            childCount: messages.length + 1, // +1 for loading indicator
                            findChildIndexCallback: (Key key) {
                              // Optimize for efficient reordering
                              if (key is ValueKey<String>) {
                                final index = messages.indexWhere((m) => m.id == key.value);
                                return index != -1 ? messages.length - 1 - index : null;
                              }
                              return null;
                            },
                          ),
                        ),
                      ],
                    ),

                    // Scroll to bottom FAB
                    if (screenState.showScrollToBottom)
                      Positioned(
                        right: 16,
                        bottom: 80,
                        child: FloatingActionButton.small(
                          onPressed: _scrollToBottom,
                          child: const Icon(Icons.arrow_downward),
                        ),
                      ),
                  ],
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) => Center(
                child: Text('Error: $error'),
              ),
            ),
          ),

          // Input bar
          MessageInput(
            conversationId: widget.conversationId,
            focusNode: _inputFocusNode,
            onSendMessage: (text) async {
              await ref
                  .read(chatScreenControllerProvider(widget.conversationId).notifier)
                  .sendMessage(text);

              // Scroll to bottom on send
              Future.delayed(const Duration(milliseconds: 100), () {
                if (_scrollController.hasClients) {
                  _scrollToBottom();
                }
              });
            },
          ),
        ],
      ),
    );
  }

  void _onMessageLongPress(Message message) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy'),
              onTap: () {
                // Copy to clipboard
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Reply'),
              onTap: () {
                // Set reply-to
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.forward),
              title: const Text('Forward'),
              onTap: () {
                // Forward message
                Navigator.pop(context);
              },
            ),
            if (message.senderDeviceId == 'me')
              ListTile(
                leading: const Icon(Icons.delete),
                title: const Text('Delete'),
                onTap: () {
                  // Delete message
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
  }
}
