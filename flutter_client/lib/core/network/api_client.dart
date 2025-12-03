// API Client for HTTP requests with authentication
// This is imported by auth_repository.dart but not used directly yet
// Will be needed for other API calls (conversations, messages, etc.)

class ApiClient {
  final String baseUrl;

  ApiClient({required this.baseUrl});

  // Methods will be implemented as needed
  // For now, auth_repository uses http package directly
}
