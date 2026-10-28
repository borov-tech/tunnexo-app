import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/plugins/app.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show Intl;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// In-app updates from GitHub Releases.
///
/// Checks at startup and every few hours; when a newer version exists it
/// offers "Update", downloads the right file (Windows installer / APK for the
/// phone's CPU) with a progress bar and starts the installation:
///  - Windows: runs the installer silently; it closes Tunnexo, installs over
///    it and starts the new version.
///  - Android: opens the system "install update" screen.
class AppUpdater {
  AppUpdater._();

  static Timer? _timer;
  static bool _busy = false;
  static const _snoozePrefix = 'update_snoozed_';
  static const _snooze = Duration(hours: 20);

  static bool get _en =>
      Intl.getCurrentLocale().toLowerCase().startsWith('en');

  /// Startup + periodic background check.
  static void start() {
    if (!(Platform.isWindows || Platform.isAndroid)) return;
    unawaited(Future<void>.delayed(const Duration(seconds: 8), () => check()));
    _timer ??= Timer.periodic(const Duration(hours: 6), (_) => check());
  }

  /// Background check: silent on errors, respects "Later" for a while.
  static Future<void> check() async {
    if (_busy || globalState.isPre) return;
    try {
      final data = await request.checkForUpdate();
      if (data == null) return;
      final tag = '${data['tag_name']}';
      final prefs = await SharedPreferences.getInstance();
      final snoozed = prefs.getInt('$_snoozePrefix$tag');
      if (snoozed != null &&
          DateTime.now()
                  .difference(DateTime.fromMillisecondsSinceEpoch(snoozed)) <
              _snooze) {
        return;
      }
      await offer(data);
    } catch (e) {
      commonPrint.log('[AppUpdater] check failed: $e');
    }
  }

  /// Shows the "new version" dialog for a GitHub release [data].
  static Future<void> offer(Map<String, dynamic> data) async {
    if (_busy) return;
    if (globalState.navigatorKey.currentState == null) return;
    final tag = '${data['tag_name']}';
    final newVersion = tag.replaceFirst(RegExp('^v'), '');
    final current = globalState.packageInfo.version;
    final notes = '${data['body'] ?? ''}'.trim();
    final en = _en;

    final res = await globalState.showCommonDialog<bool>(
      child: Builder(
        builder: (context) => CommonDialog(
          title: en ? 'Update available' : 'Доступна новая версия',
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(en ? 'Later' : 'Позже'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(en ? 'Update' : 'Обновить'),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Tunnexo $newVersion',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                en ? 'You have $current' : 'У вас установлена $current',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(notes, style: Theme.of(context).textTheme.bodyMedium),
              ],
              const SizedBox(height: 12),
              Text(
                en
                    ? 'Your subscription and settings are kept.'
                    : 'Подписка и настройки сохранятся.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
    if (res != true) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          '$_snoozePrefix$tag', DateTime.now().millisecondsSinceEpoch);
      return;
    }
    await _install(data);
  }

  static Future<String?> _assetUrl(Map<String, dynamic> data) async {
    final assets = (data['assets'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();
    String? find(String name) {
      for (final a in assets) {
        if (a['name'] == name) return '${a['browser_download_url']}';
      }
      return null;
    }

    if (Platform.isWindows) {
      return find('Tunnexo-windows-amd64-setup.exe');
    }
    if (Platform.isAndroid) {
      var abis = <String>[];
      try {
        abis = (await DeviceInfoPlugin().androidInfo).supportedAbis;
      } catch (_) {}
      for (final abi in abis) {
        final url = find('Tunnexo-android-$abi.apk');
        if (url != null) return url;
      }
      return find('Tunnexo-android-universal.apk');
    }
    return null;
  }

  static Future<void> _install(Map<String, dynamic> data) async {
    if (_busy) return;
    _busy = true;
    final en = _en;
    final tag = '${data['tag_name']}';
    final progress = ValueNotifier<double?>(null);
    final status = ValueNotifier<String>(
        en ? 'Downloading the update…' : 'Скачиваем обновление…');
    final cancel = CancelToken();
    var dialogOpen = true;

    unawaited(globalState
        .showCommonDialog<void>(
          dismissible: false,
          child: Builder(
            builder: (context) => CommonDialog(
              title: 'Tunnexo ${tag.replaceFirst(RegExp('^v'), '')}',
              actions: [
                TextButton(
                  onPressed: () {
                    cancel.cancel();
                    Navigator.of(context).pop();
                  },
                  child: Text(en ? 'Cancel' : 'Отмена'),
                ),
              ],
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ValueListenableBuilder<String>(
                    valueListenable: status,
                    builder: (_, text, __) => Text(text),
                  ),
                  const SizedBox(height: 14),
                  ValueListenableBuilder<double?>(
                    valueListenable: progress,
                    builder: (_, value, __) => Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: value,
                            minHeight: 8,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(value == null
                            ? ''
                            : '${(value * 100).clamp(0, 100).round()}%'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        )
        .whenComplete(() => dialogOpen = false));

    void closeDialog() {
      if (dialogOpen) {
        globalState.navigatorKey.currentState?.pop();
        dialogOpen = false;
      }
    }

    try {
      final url = await _assetUrl(data);
      if (url == null) throw Exception('no file for this device');
      final dir = Platform.isAndroid
          ? await getApplicationSupportDirectory()
          : await getTemporaryDirectory();
      final updates = Directory('${dir.path}${Platform.pathSeparator}updates');
      if (await updates.exists()) {
        await updates.delete(recursive: true);
      }
      await updates.create(recursive: true);
      final name = Uri.parse(url).pathSegments.last;
      final path = '${updates.path}${Platform.pathSeparator}$name';

      await Dio().download(
        url,
        path,
        cancelToken: cancel,
        options: Options(receiveTimeout: const Duration(minutes: 10)),
        onReceiveProgress: (received, total) {
          if (total > 0) progress.value = received / total;
        },
      );

      if (Platform.isWindows) {
        status.value = en
            ? 'Installing… Tunnexo will restart by itself.'
            : 'Устанавливаем… Tunnexo перезапустится сам.';
        progress.value = null;
        // `start` goes through ShellExecute, so Windows can show the UAC
        // prompt the installer needs. The installer closes Tunnexo, installs
        // over it and launches the new version (see inno_setup.iss).
        await Process.start(
          'cmd',
          ['/c', 'start', '', path, '/SILENT', '/SP-', '/SUPPRESSMSGBOXES',
            '/NORESTART'],
          runInShell: false,
          mode: ProcessStartMode.detached,
        );
        return;
      }

      if (Platform.isAndroid) {
        closeDialog();
        final result = await app?.installApk(path) ?? 'error';
        if (result == 'need_permission') {
          await globalState.showMessage(
            title: en ? 'One more step' : 'Ещё один шаг',
            message: TextSpan(
              text: en
                  ? 'Allow Tunnexo to install updates in the settings that '
                      'just opened, come back and tap “Update” again.'
                  : 'В открывшихся настройках разрешите Tunnexo устанавливать '
                      'приложения, вернитесь и нажмите «Обновить» ещё раз.',
            ),
            cancelable: false,
          );
          _busy = false;
          await offer(data);
        }
        return;
      }
    } catch (e) {
      commonPrint.log('[AppUpdater] install failed: $e');
      closeDialog();
      if (e is DioException && CancelToken.isCancel(e)) return;
      final res = await globalState.showMessage(
        title: en ? 'Could not update' : 'Не удалось обновить',
        message: TextSpan(
          text: en
              ? 'Download the new version from the website instead.'
              : 'Скачайте новую версию с сайта — это займёт минуту.',
        ),
        confirmText: en ? 'Open website' : 'Открыть сайт',
      );
      if (res == true) {
        final page = Platform.isAndroid ? 'android' : 'windows';
        unawaited(launchUrl(
          Uri.parse('https://tunnexo.com/get/$page.html'),
          mode: LaunchMode.externalApplication,
        ));
      }
    } finally {
      _busy = false;
    }
  }
}
