import 'dart:convert';
import 'dart:io';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/plugins/vpn.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show Intl;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Subscription expiry reminders: 3 days and 1 day before the end.
///
/// Android: a system notification with a "Renew" action.
/// Desktop: a dialog in the app window ("Renew" / "Later") — shown right away
/// if the window is open, otherwise the next time it is opened.
/// Each reminder is shown once per subscription period (expire timestamp).
class SubscriptionNotificationService {
  static const String _prefsKeyPrefix = 'subscription_notified_';

  /// Reminder buckets: "3" covers 2–3 days left, "1" covers the last day.
  static const List<int> notificationDays = [3, 1];

  static bool get _en =>
      Intl.getCurrentLocale().toLowerCase().startsWith('en');

  static Future<void> checkAndNotify(Profile profile) async {
    final subscriptionInfo = profile.subscriptionInfo;
    if (subscriptionInfo == null) return;
    final expire = subscriptionInfo.expire;
    if (expire == 0) return;

    final left = DateTime.fromMillisecondsSinceEpoch(expire * 1000)
        .difference(DateTime.now());
    if (left.isNegative) return;
    final days = left.inDays;
    final int threshold;
    if (days <= 1) {
      threshold = 1;
    } else if (days <= 3) {
      threshold = 3;
    } else {
      return;
    }
    commonPrint.log(
        '[SubscriptionNotification] $days day(s) left, bucket $threshold');
    await _showNotificationIfNeeded(profile, threshold, days);
  }

  static String _ruDays(int n) {
    final m100 = n % 100;
    if (m100 >= 11 && m100 <= 14) return 'дней';
    switch (n % 10) {
      case 1:
        return 'день';
      case 2:
      case 3:
      case 4:
        return 'дня';
      default:
        return 'дней';
    }
  }

  static String _headline(int days) {
    if (_en) {
      if (days <= 0) return 'Your subscription ends today';
      if (days == 1) return 'Your subscription ends tomorrow';
      return 'Your subscription ends in $days days';
    }
    if (days <= 0) return 'Подписка заканчивается сегодня';
    if (days == 1) return 'Подписка заканчивается завтра';
    return 'Подписка заканчивается через $days ${_ruDays(days)}';
  }

  static String get _body => _en
      ? 'Renew it so your connection is not interrupted.'
      : 'Продлите её, чтобы подключение не прервалось.';

  static String _decodeHeader(String? value) {
    if (value == null || value.trim().isEmpty) return '';
    try {
      return utf8.decode(base64.decode(base64.normalize(value.trim()))).trim();
    } catch (_) {
      return value.trim();
    }
  }

  static Future<void> _showNotificationIfNeeded(
    Profile profile,
    int threshold,
    int days,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _getPrefsKey(profile.id, threshold);
    final currentExpire = profile.subscriptionInfo?.expire ?? 0;
    if (prefs.getInt(key) == currentExpire) return;

    final headers = profile.providerHeaders;
    // Where "Renew" leads: the buy-plan link, then support, then our bot.
    var renewUrl = (headers['flclashx-buyplan'] ?? '').trim();
    if (renewUrl.isEmpty) renewUrl = (headers['support-url'] ?? '').trim();
    if (renewUrl.isEmpty) renewUrl = tunnexoBotUrl;

    final service = _decodeHeader(headers['flclashx-servicename']);
    final title =
        service.isNotEmpty ? service : (profile.label ?? appName);
    final headline = _headline(days);
    final renew = _en ? 'Renew' : 'Продлить';

    if (Platform.isAndroid) {
      await vpn?.showSubscriptionNotification(
        title: title,
        message: '$headline. $_body',
        actionLabel: renew,
        actionUrl: renewUrl,
      );
    } else {
      // Mark first so a second profile refresh doesn't stack another dialog.
      await prefs.setInt(key, currentExpire);
      await _showDesktopReminder(headline, renew, renewUrl);
      return;
    }
    await prefs.setInt(key, currentExpire);
  }

  static Future<void> _showDesktopReminder(
    String headline,
    String renew,
    String renewUrl,
  ) async {
    // Startup refreshes can run before the navigator exists.
    for (var i = 0; i < 30 && globalState.navigatorKey.currentState == null; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (globalState.navigatorKey.currentState == null) return;
    final res = await globalState.showCommonDialog<bool>(
      child: Builder(
        builder: (context) => CommonDialog(
          title: headline,
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_en ? 'Later' : 'Позже'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(renew),
            ),
          ],
          child: Text(_body),
        ),
      ),
    );
    if (res == true) {
      try {
        await launchUrl(Uri.parse(renewUrl),
            mode: LaunchMode.externalApplication);
      } catch (e) {
        commonPrint.log('[SubscriptionNotification] open renew url: $e');
      }
    }
  }

  static String _getPrefsKey(String profileId, int days) =>
      '$_prefsKeyPrefix${profileId}_${days}d';

  /// Reset notification state for a profile (call when subscription is renewed)
  static Future<void> resetNotifications(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    for (final days in notificationDays) {
      await prefs.remove(_getPrefsKey(profileId, days));
    }
  }
}
