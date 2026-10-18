import 'package:permission_handler/permission_handler.dart';

import '../analytics/analytics_service.dart';

/// Requests permissions only for the feature that needs them, and reports the
/// answer as `permission_result`.
Future<bool> requestPermission(Permission p, String name, AnalyticsService analytics) async {
  final status = await p.request();
  analytics.log('permission_result', {'permission': name, 'granted': status.isGranted});
  return status.isGranted;
}
