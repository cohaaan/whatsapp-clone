# Production Deployment Guide

## Prerequisites

- [Fly.io CLI](https://fly.io/docs/hands-on/install-flyctl/) installed
- Elixir 1.16+ and Erlang/OTP 26+ installed locally
- Flutter 3.x SDK installed
- PostgreSQL 16+ (local development)
- Apple Developer Account (for APNs)
- Firebase Project (for FCM)

---

## Step 1: Backend Setup (Local Development)

### 1.1 Install Dependencies
```bash
cd backend
mix deps.get
mix deps.compile
```

### 1.2 Configure Database
```bash
# Create database
mix ecto.create

# Run migrations
mix ecto.migrate
```

### 1.3 Configure Environment Variables
```bash
# .env.dev (gitignored)
export DATABASE_URL="ecto://postgres:postgres@localhost/chat_dev"
export SECRET_KEY_BASE="<run: mix phx.gen.secret>"
export JWT_SECRET="<run: mix phx.gen.secret>"
export RELEASE_COOKIE="<run: mix phx.gen.secret>"
```

### 1.4 Start Server
```bash
source .env.dev
mix phx.server

# Server running at http://localhost:4000
```

### 1.5 Test WebSocket Connection
```bash
# Install wscat
npm install -g wscat

# Generate a test JWT token first (from IEx)
iex -S mix
iex> Chat.Auth.generate_access_token("test-user-id", "test-device-id")

# Connect to socket
wscat -c "ws://localhost:4000/socket/websocket?token=<your-jwt-token>"

# Join conversation
{"topic":"conversation:test-conv-id","event":"phx_join","payload":{},"ref":"1"}
```

---

## Step 2: Fly.io Production Deployment

### 2.1 Create Fly.io App
```bash
cd backend
fly launch --no-deploy

# Follow prompts:
# - App name: chat-prod
# - Region: iad (or nearest to you)
# - Skip database setup (we'll create manually)
```

### 2.2 Provision PostgreSQL
```bash
# Create Postgres cluster (recommended: 2x shared-cpu-1x with 1GB RAM)
fly postgres create --name chat-db \
  --region iad \
  --initial-cluster-size 2 \
  --vm-size shared-cpu-1x \
  --volume-size 10

# Attach to app
fly postgres attach chat-db --app chat-prod

# This sets DATABASE_URL automatically
```

### 2.3 Configure Secrets
```bash
# Generate secrets
SECRET_KEY_BASE=$(mix phx.gen.secret)
JWT_SECRET=$(mix phx.gen.secret)
RELEASE_COOKIE=$(mix phx.gen.secret)

# Set secrets
fly secrets set \
  SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  JWT_SECRET="$JWT_SECRET" \
  RELEASE_COOKIE="$RELEASE_COOKIE" \
  PHX_HOST="chat-prod.fly.dev" \
  --app chat-prod
```

### 2.4 Configure APNs (Push Notifications)
```bash
# 1. Generate APNs Auth Key (.p8 file) from Apple Developer Console
# 2. Note: Key ID and Team ID

# Create directory for certificates
mkdir -p certs

# Copy .p8 file
cp ~/Downloads/AuthKey_ABC123.p8 certs/apns.p8

# Set secrets
fly secrets set \
  APNS_KEY_ID="ABC123" \
  APNS_TEAM_ID="XYZ789" \
  APNS_P8_FILE_PATH="/app/certs/apns.p8" \
  --app chat-prod
```

### 2.5 Configure FCM (Firebase Cloud Messaging)
```bash
# 1. Download service account JSON from Firebase Console
# 2. Minify JSON (remove whitespace)

# Set secret (paste entire JSON)
fly secrets set \
  FCM_SERVICE_ACCOUNT_JSON='{"type":"service_account",...}' \
  --app chat-prod
```

### 2.6 Update Dockerfile to Include Certificates
```dockerfile
# Add to runtime stage (after WORKDIR /app)
COPY --from=builder /app/certs /app/certs
```

### 2.7 Deploy
```bash
# First deployment
fly deploy --ha=false

# Check status
fly status

# View logs
fly logs
```

### 2.8 Run Migrations
```bash
# SSH into running instance
fly ssh console --app chat-prod

# Run migrations
bin/chat eval "Chat.Release.migrate()"

# Exit
exit
```

### 2.9 Scale to HA (High Availability)
```bash
# Scale to 2 instances
fly scale count 2 --region iad

# Upgrade VM
fly scale vm performance-4x --memory 8192

# Verify
fly status
```

---

## Step 3: Database Optimization

### 3.1 Enable pg_partman Extension
```bash
# SSH to Postgres leader
fly postgres connect --app chat-db

# Enable extension
CREATE EXTENSION IF NOT EXISTS pg_partman;

# Verify
\dx pg_partman
```

### 3.2 Configure Autovacuum
```sql
-- Connect to database
fly postgres connect --app chat-db

\c chat_prod

-- Tune autovacuum for high-write tables
ALTER TABLE message_envelopes SET (
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_analyze_scale_factor = 0.02,
  autovacuum_vacuum_cost_limit = 2000
);

ALTER TABLE messages SET (
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_analyze_scale_factor = 0.02
);

ALTER TABLE idempotency_keys SET (
  autovacuum_vacuum_scale_factor = 0.1
);
```

### 3.3 Schedule Partition Maintenance
```elixir
# Add to lib/chat/application.ex (or use Oban)

defmodule Chat.Workers.PartitionMaintenance do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{})
  end

  def init(state) do
    schedule_maintenance()
    {:ok, state}
  end

  def handle_info(:run_maintenance, state) do
    Chat.Repo.query("SELECT partman.run_maintenance('public.messages')")
    schedule_maintenance()
    {:noreply, state}
  end

  defp schedule_maintenance do
    # Run daily at 2 AM UTC
    Process.send_after(self(), :run_maintenance, :timer.hours(24))
  end
end

# Add to supervision tree
children = [
  # ...
  Chat.Workers.PartitionMaintenance
]
```

---

## Step 4: Monitoring & Observability

### 4.1 Set Up Prometheus
```bash
# Metrics exposed at https://chat-prod.fly.dev/metrics

# Add to Prometheus config (prometheus.yml)
scrape_configs:
  - job_name: 'chat-prod'
    metrics_path: '/metrics'
    static_configs:
      - targets: ['chat-prod.fly.dev']
```

### 4.2 Set Up Grafana Dashboards
```bash
# Import PromEx dashboards:
# 1. BEAM VM Dashboard (ID: provided by PromEx)
# 2. Phoenix Dashboard
# 3. Ecto Dashboard
# 4. Custom Chat Metrics (from IMPLEMENTATION_SUMMARY.md)
```

### 4.3 Configure Alerts
```yaml
# alerts.yml
groups:
  - name: chat_critical
    rules:
      - alert: HighMessageLatency
        expr: histogram_quantile(0.99, chat_message_delivery_latency_bucket) > 5000
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "P99 message delivery > 5s"

      - alert: DatabasePoolExhausted
        expr: ecto_repo_available_connections{repo="Chat.Repo"} < 2
        for: 1m
        labels:
          severity: critical

      - alert: BEAMSchedulersOverloaded
        expr: vm_total_run_queue_lengths > 20
        for: 2m
        labels:
          severity: warning
```

### 4.4 Set Up PagerDuty (Optional)
```bash
# Install Alertmanager webhook integration
# Configure in Prometheus alertmanager.yml
```

---

## Step 5: Flutter App Build & Release

### 5.1 Configure Environment
```dart
// lib/config/environment.dart
class Environment {
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://chat-prod.fly.dev',
  );

  static const String wsUrl = String.fromEnvironment(
    'WS_URL',
    defaultValue: 'wss://chat-prod.fly.dev',
  );
}
```

### 5.2 iOS Build
```bash
cd flutter_client

# Install dependencies
flutter pub get

# Generate code (Drift, Riverpod, etc.)
flutter pub run build_runner build --delete-conflicting-outputs

# Build iOS
flutter build ios --release \
  --dart-define=API_BASE_URL=https://chat-prod.fly.dev \
  --dart-define=WS_URL=wss://chat-prod.fly.dev

# Open Xcode for signing and upload
open ios/Runner.xcworkspace

# Archive and upload to App Store Connect
```

### 5.3 Android Build
```bash
# Build APK
flutter build apk --release \
  --dart-define=API_BASE_URL=https://chat-prod.fly.dev \
  --dart-define=WS_URL=wss://chat-prod.fly.dev

# Build App Bundle (for Play Store)
flutter build appbundle --release \
  --dart-define=API_BASE_URL=https://chat-prod.fly.dev \
  --dart-define=WS_URL=wss://chat-prod.fly.dev

# Upload to Google Play Console
```

### 5.4 Configure Push Notifications

**iOS (APNs)**:
```swift
// ios/Runner/AppDelegate.swift
import UIKit
import Flutter
import UserNotifications

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Request notification permissions
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
      if granted {
        DispatchQueue.main.async {
          application.registerForRemoteNotifications()
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let tokenParts = deviceToken.map { String(format: "%02.2hhx", $0) }
    let token = tokenParts.joined()

    // Send to Flutter
    let channel = FlutterMethodChannel(name: "com.example.chat/push", binaryMessenger: (window?.rootViewController as! FlutterViewController).binaryMessenger)
    channel.invokeMethod("onTokenRefresh", arguments: token)
  }
}
```

**Android (FCM)**:
```kotlin
// android/app/src/main/kotlin/com/example/chat/Application.kt
class Application : FlutterApplication() {
    override fun onCreate() {
        super.onCreate()
        FirebaseApp.initializeApp(this)
    }
}

// android/app/src/main/kotlin/com/example/chat/FirebaseMessagingService.kt
class FirebaseMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(remoteMessage: RemoteMessage) {
        // Show notification
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val notification = NotificationCompat.Builder(this, "chat_messages")
            .setContentTitle(remoteMessage.data["sender_name"])
            .setContentText("You have a new message")
            .setSmallIcon(R.drawable.ic_notification)
            .setAutoCancel(true)
            .build()

        notificationManager.notify(0, notification)
    }

    override fun onNewToken(token: String) {
        // Send to Flutter
        val intent = Intent("com.example.chat.TOKEN_REFRESH")
        intent.putExtra("token", token)
        sendBroadcast(intent)
    }
}
```

---

## Step 6: Testing & Validation

### 6.1 Backend Unit Tests
```bash
cd backend
MIX_ENV=test mix test

# Run specific test
mix test test/chat/messaging_test.exs

# With coverage
mix test --cover
```

### 6.2 Load Testing (Artillery)
```yaml
# artillery.yml
config:
  target: "wss://chat-prod.fly.dev"
  phases:
    - duration: 60
      arrivalRate: 10
      name: "Warm up"
    - duration: 300
      arrivalRate: 50
      name: "Sustained load"

scenarios:
  - name: "Send messages"
    engine: "ws"
    flow:
      - connect:
          url: "/socket/websocket?token={{ token }}"
      - send:
          channel: "conversation:test"
          event: "msg:send"
          data:
            idempotency_key: "{{ $randomString() }}"
            envelope: "..."
      - think: 5
```

Run:
```bash
artillery run artillery.yml
```

### 6.3 Flutter Integration Tests
```bash
cd flutter_client

# Run integration tests
flutter test integration_test/

# Run on device
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/app_test.dart
```

### 6.4 E2E Message Encryption Test
```dart
// test/signal_protocol_test.dart
void main() {
  test('E2E encryption - Alice sends to Bob', () async {
    // 1. Alice generates identity key
    final aliceIdentity = await signalProtocol.generateIdentityKeyPair();

    // 2. Bob generates prekey bundle
    final bobBundle = await signalProtocol.generatePreKeyBundle(100);

    // 3. Alice initiates session with Bob's bundle
    await signalProtocol.initSessionFromBundle('bob-device', bobBundle);

    // 4. Alice encrypts message
    final plaintext = 'Hello, Bob!';
    final ciphertext = await signalProtocol.encrypt('bob-device', utf8.encode(plaintext));

    // 5. Bob decrypts message
    final decrypted = await signalProtocol.decrypt('alice-device', ciphertext);

    expect(utf8.decode(decrypted), equals(plaintext));
  });
}
```

---

## Step 7: Production Checklist

### 7.1 Security
- [ ] All secrets in Fly.io secrets (not committed to git)
- [ ] Force HTTPS enabled
- [ ] Certificate pinning configured in Flutter
- [ ] Rate limiting active on all endpoints
- [ ] JWT expiry set correctly (15 min access, 7 day refresh)
- [ ] Phone numbers hashed and encrypted
- [ ] Logging excludes PII

### 7.2 Performance
- [ ] Database indexes created
- [ ] pg_partman configured and running
- [ ] Autovacuum tuned
- [ ] BEAM VM tuning applied
- [ ] Connection pool sized correctly
- [ ] Idempotency L1 cache hit rate > 95%

### 7.3 Reliability
- [ ] HA deployment (min 2 instances)
- [ ] Database backups enabled (Fly.io automatic)
- [ ] Health checks configured
- [ ] Monitoring and alerts set up
- [ ] Push notification error handling
- [ ] Offline queue drains on reconnect

### 7.4 Compliance
- [ ] Privacy policy updated
- [ ] Terms of service updated
- [ ] Data retention policy documented
- [ ] GDPR compliance (data export/deletion)
- [ ] E2E encryption disclosed in app store listings

---

## Step 8: Post-Launch Operations

### 8.1 Daily Tasks
- [ ] Check error rates in logs
- [ ] Monitor alert notifications
- [ ] Review P99 latency metrics
- [ ] Check database connection pool usage

### 8.2 Weekly Tasks
- [ ] Review slow query log
- [ ] Check partition creation (should be 4 months ahead)
- [ ] Audit device token cleanup (invalid tokens deleted?)
- [ ] Review rate limit violations

### 8.3 Monthly Tasks
- [ ] REINDEX CONCURRENTLY on critical indexes
- [ ] Review database bloat
- [ ] Audit user growth vs capacity
- [ ] Review and rotate secrets if needed
- [ ] Update dependencies (security patches)

---

## Troubleshooting

### Issue: High Message Latency
**Symptom**: P99 latency > 1s

**Debug**:
```bash
# Check run queue
fly ssh console
iex> :erlang.statistics(:run_queue_lengths)

# Check DB pool
iex> :ecto_sql.pool_status(Chat.Repo)

# Check slow queries
fly postgres connect --app chat-db
SELECT query, mean_exec_time FROM pg_stat_statements ORDER BY mean_exec_time DESC LIMIT 10;
```

**Fix**:
- Add missing indexes
- Increase VM resources
- Tune autovacuum

---

### Issue: WebSocket Disconnections
**Symptom**: Clients frequently reconnect

**Debug**:
```bash
# Check connection count
fly ssh console
iex> Registry.count(Phoenix.PubSub)

# Check for errors
fly logs --app chat-prod | grep "socket"
```

**Fix**:
- Increase concurrency limits in fly.toml
- Check network issues
- Tune heartbeat interval

---

### Issue: Push Notifications Not Delivered
**Symptom**: Users not receiving push

**Debug**:
```bash
# Check Broadway pipeline
fly ssh console
iex> Broadway.producer_names(Chat.Push.BroadwayPipeline)

# Check Pigeon
iex> Pigeon.APNS.Notification.push(test_notification)
```

**Fix**:
- Verify APNs/FCM credentials
- Check device token validity
- Review push notification logs

---

## Scaling Beyond Initial Deployment

### To 100K Users
- Upgrade VM to `performance-8x` (8 vCPU, 16GB)
- Scale Postgres to `dedicated-cpu-2x`
- Increase connection pool to 50
- Add Redis for Presence (optional)

### To 1M Users
- Deploy to multiple regions (iad, lhr, nrt)
- Use Fly.io regional read replicas
- Implement CDN for static assets
- Consider managed Postgres (RDS, Crunchy)
- Add dedicated push notification workers

### To 10M+ Users
- Consult with Fly.io for enterprise support
- Consider multi-cloud strategy
- Implement horizontal message sharding
- Dedicated analytics infrastructure

---

**END OF DEPLOYMENT GUIDE**
