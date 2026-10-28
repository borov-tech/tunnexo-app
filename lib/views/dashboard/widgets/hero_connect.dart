import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flclashx/clash/clash.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/plugins/app.dart' as app_plugin;
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/views/profiles/add_profile.dart';
import 'package:flclashx/widgets/rolling_text.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart' show Intl;
import 'package:url_launcher/url_launcher.dart';

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

// True while a user-started connection is being brought up: drives the button
// shimmer and the rings around the logo.
final _heroConnecting = ValueNotifier<bool>(false);

// Short "Protected · country" confirmation shown above the connect button.
final _heroToast = ValueNotifier<String?>(null);
Timer? _heroToastTimer;

void _showHeroToast(String text) {
  _heroToastTimer?.cancel();
  _heroToast.value = text;
  _heroToastTimer = Timer(const Duration(milliseconds: 2600), () {
    _heroToast.value = null;
  });
}

// Connect failed: red button + hint above it, cleared after a while or on the
// next tap.
final _heroError = ValueNotifier<bool>(false);
// The failure was the VPN core itself not running (typically the phone killed
// or blocked Tunnexo's background process): the hint then explains how to
// allow background work and stays until the next tap.
final _heroCoreProblem = ValueNotifier<bool>(false);
Timer? _heroErrorTimer;

void _setHeroError(bool value, {bool core = false}) {
  _heroErrorTimer?.cancel();
  _heroCoreProblem.value = value && core;
  _heroError.value = value;
  if (value && !core) {
    _heroErrorTimer = Timer(const Duration(seconds: 7), () {
      _heroError.value = false;
    });
  }
}

Future<bool> _coreAlive() async {
  try {
    return await Future<bool>.value(clashCore.isInit)
        .timeout(const Duration(seconds: 4));
  } catch (_) {
    return false;
  }
}

// True for a few seconds after the first subscription was added: the connect
// button pulses to show what to press next.
final _heroDone = ValueNotifier<bool>(false);

// Tunnexo strings are Russian-first; English only when the app runs in English.
bool get _isEn => Intl.getCurrentLocale().toLowerCase().startsWith('en');

bool _reduceMotion(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;

Future<void> _launchExternal(String url) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    await globalState.openUrl(url);
  }
}

String _countryCodeToEmoji(String code) {
  if (code.length != 2) return '🌐';
  final upper = code.toUpperCase();
  final first = 0x1F1E6 - 0x41 + upper.codeUnitAt(0);
  final second = 0x1F1E6 - 0x41 + upper.codeUnitAt(1);
  return String.fromCharCodes([first, second]);
}

// Derive an ISO country code from the first regional-indicator flag emoji found
// in [text] (e.g. "🇳🇱 Amsterdam" -> "NL"). Returns null when there's no flag.
String? _flagToCountryCode(String text) {
  final runes = text.runes.toList();
  for (var i = 0; i < runes.length - 1; i++) {
    final a = runes[i];
    final b = runes[i + 1];
    if (a >= 0x1F1E6 && a <= 0x1F1FF && b >= 0x1F1E6 && b <= 0x1F1FF) {
      final c1 = a - 0x1F1E6 + 0x41;
      final c2 = b - 0x1F1E6 + 0x41;
      return String.fromCharCodes([c1, c2]);
    }
  }
  return null;
}

// Collect the distinct ISO country codes carried by the flag emoji in the names
// of every proxy in [group], descending a few levels into nested groups. Used to
// paint a faint backdrop of the group's flags behind the active one.
List<String> _collectGroupFlags(List<Group> groups, Group group) {
  final seen = <String>{};
  final codes = <String>[];
  void walk(Group g, int depth) {
    if (depth > 4) return;
    for (final proxy in g.all) {
      final code = _flagToCountryCode(proxy.name);
      if (code != null) {
        if (seen.add(code)) codes.add(code);
      } else {
        final sub = groups.getGroup(proxy.name);
        if (sub != null) walk(sub, depth + 1);
      }
    }
  }

  walk(group, 0);
  return codes;
}

// Strip only the *leading* emoji run from the name — typically the flag prefix
// (e.g. "🇳🇱 Amsterdam"), which we already render separately as the flag icon.
// Emoji that appear later in the name are kept intact.
String _stripLeadingEmoji(String text) {
  bool isEmojiRune(int r) {
    final isFlag = r >= 0x1F1E6 && r <= 0x1F1FF;
    final isModifier =
        r == 0x200D || r == 0xFE0F || (r >= 0x1F3FB && r <= 0x1F3FF);
    final isPictograph = (r >= 0x1F000 && r <= 0x1FAFF) ||
        (r >= 0x2600 && r <= 0x27BF) ||
        (r >= 0x2190 && r <= 0x21FF) ||
        (r >= 0x2B00 && r <= 0x2BFF) ||
        (r >= 0x2300 && r <= 0x23FF);
    return isFlag || isModifier || isPictograph;
  }

  bool isSpace(int r) =>
      r == 0x20 || r == 0x09 || r == 0xA0 || r == 0x0A || r == 0x0D;

  final runes = text.runes.toList();
  var start = 0;
  // Consume the leading run of emoji (and any whitespace around it) so a flag
  // prefixed with or followed by spaces is still removed; stop at the first
  // real character and keep the remainder verbatim.
  while (start < runes.length &&
      (isEmojiRune(runes[start]) || isSpace(runes[start]))) {
    start++;
  }
  return String.fromCharCodes(runes.sublist(start))
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  return '${value.toStringAsFixed(1)} ${units[i]}';
}

// Russian-aware plural form for "days" (mirrors MetainfoWidget's declension).
String _daysWord(int days) {
  if (days % 100 >= 11 && days % 100 <= 19) return appLocalizations.days;
  switch (days % 10) {
    case 1:
      return appLocalizations.day;
    case 2:
    case 3:
    case 4:
      return appLocalizations.daysGenitive;
    default:
      return appLocalizations.days;
  }
}

String? _decodeAnnounce(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final decoded = _decodeBase64(trimmed);
  if (decoded == null || decoded.trim().isEmpty) return null;
  return decoded.trim();
}

String? _decodeBase64(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  var text = value.trim();
  if (text.startsWith('base64:')) text = text.substring(7).trim();
  if (text.isEmpty) return null;
  try {
    final normalized = base64.normalize(text);
    final decoded = utf8.decode(base64.decode(normalized)).trim();
    return decoded.isEmpty ? null : decoded;
  } catch (_) {
    return value.trim().isEmpty ? null : value.trim();
  }
}

// ----------------------------------------------------------------------------
// Focusable tap wrapper — makes a tappable area reachable by a D-pad/remote
// (Android TV). The hero board's controls were bare GestureDetectors, which
// have no focus node and don't respond to D-pad-center/Enter, so the TV remote
// couldn't focus or activate them. This adds a focus node, a primary-colour ring
// + subtle scale while focused, and activates onTap on both tap and Enter/Select.
// ----------------------------------------------------------------------------
class _FocusableTap extends StatefulWidget {
  const _FocusableTap({
    required this.onTap,
    required this.child,
    this.autofocus = false,
    this.borderRadius = 18,
  });

  final VoidCallback? onTap;
  final Widget child;
  final bool autofocus;
  final double borderRadius;

  @override
  State<_FocusableTap> createState() => _FocusableTapState();
}

class _FocusableTapState extends State<_FocusableTap> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return FocusableActionDetector(
      enabled: enabled,
      autofocus: widget.autofocus && enabled,
      onShowFocusHighlight: (value) {
        if (mounted && value != _focused) setState(() => _focused = value);
      },
      // No explicit Map<Type, Action<Intent>> annotation: `Action` is ambiguous here
      // (flclashx models also export an `Action` class). Context inference from
      // FocusableActionDetector.actions gives the right type without naming it.
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      // Focus ring only — no scale-up. AnimatedScale painted outside the layout
      // bounds, so a full-width autofocused control (the connect button on
      // desktop) spilled past the window edges once 1.5% of its width exceeded
      // the 16px side padding.
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.borderRadius + 4),
          border: Border.all(
            color:
                _focused ? context.colorScheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: widget.child,
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// Hero
// ----------------------------------------------------------------------------
class HeroConnect extends ConsumerWidget {
  const HeroConnect({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(startButtonSelectorStateProvider);
    if (!state.hasProfile) return const _EmptyHero();

    final isReady = state.isInit;
    final profile = ref.watch(currentProfileProvider);
    final headers = profile?.providerHeaders ?? {};
    final serviceName = _decodeBase64(headers['flclashx-servicename']) ?? appName;
    final logoUrl = _decodeBase64(headers['flclashx-servicelogo']);
    final announce = _decodeAnnounce(headers['announce']);
    final sub = profile?.subscriptionInfo;
    // Only show the traffic card when there's something to show — a data limit or an
    // expiry. Unlimited + no expiry => hide it entirely.
    final hasSub = sub != null && (sub.total > 0 || sub.expire > 0);

    // Buy/renew links carried by the profile. The buttons (under the traffic
    // card) only appear when the matching condition is met:
    //   buyplan    -> less than 3 days left (expired included), time-limited plans
    //   buytraffic -> less than 10% of the limit remaining, capped plans
    final buyPlanUrl = headers['flclashx-buyplan'];
    final buyTrafficUrl = headers['flclashx-buytraffic'];
    var showBuyPlan = false;
    var showBuyTraffic = false;
    if (sub != null) {
      if (buyPlanUrl != null && buyPlanUrl.isNotEmpty && sub.expire > 0) {
        showBuyPlan = DateTime.fromMillisecondsSinceEpoch(sub.expire * 1000)
                .difference(DateTime.now()) <
            const Duration(days: 3);
      }
      if (buyTrafficUrl != null && buyTrafficUrl.isNotEmpty && sub.total > 0) {
        final used = sub.upload + sub.download;
        showBuyTraffic = (sub.total - used) < sub.total * 0.1;
      }
    }
    final showBuy = showBuyPlan || showBuyTraffic;

    final groups = ref.watch(currentGroupsStateProvider).value;
    var serverName = '';
    String? testUrl;
    Group? activeGroup;
    // Server label = the current pick of the proxy group named in the
    // `flclashx-serverinfo` header: its selected leaf host (the real location),
    // or the sub-group's own name when the pick is itself a group (see
    // resolveToDisplayName). Fall back to the first group with a live selection.
    final serverInfoHeader = headers['flclashx-serverinfo'];
    if (serverInfoHeader != null && serverInfoHeader.isNotEmpty) {
      final groupName = _decodeBase64(serverInfoHeader) ?? serverInfoHeader.trim();
      final group = groups.getGroup(groupName);
      if (group != null) {
        activeGroup = group;
        serverName = groups.resolveToDisplayName(group.name);
        testUrl = group.testUrl;
      }
    }
    if (serverName.isEmpty) {
      for (final g in groups) {
        final now = g.realNow;
        if (now.isNotEmpty && now != 'DIRECT' && now != 'REJECT') {
          activeGroup = g;
          serverName = groups.resolveToDisplayName(g.name);
          testUrl = g.testUrl;
          break;
        }
      }
    }
    final displayName = _stripLeadingEmoji(serverName);
    final nameCountryCode = _flagToCountryCode(serverName);
    final groupFlagCodes =
        activeGroup != null ? _collectGroupFlags(groups, activeGroup) : const <String>[];
    // Other locations in the group: their distinct flag countries (shown as stacked
    // flags behind the active one) plus a total count (the badge). Falls back to the
    // sibling-proxy count when node names carry no flag emoji.
    final activeUpper = nameCountryCode?.toUpperCase();
    final otherCodes =
        groupFlagCodes.where((c) => c.toUpperCase() != activeUpper).toList();
    final rawOther = otherCodes.isNotEmpty
        ? otherCodes.length
        : (activeGroup != null ? activeGroup.all.length - 1 : 0);
    final otherLocations = rawOther < 0 ? 0 : rawOther;

    return Column(
      children: [
        Expanded(
          child: _DoneSwitch(
          child: SingleChildScrollView(
            child: Column(
              children: [
                const SizedBox(height: 8),
                _LogoWithRings(child: _Logo(logoUrl: logoUrl)),
                const SizedBox(height: 16),
                Text(
                  serviceName,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (announce != null && announce.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _AnnounceBanner(text: announce),
                ],
                const SizedBox(height: 18),
                _HeroActionRow(
                  isUpdating: profile?.isUpdating ?? false,
                  onUpdate: profile == null
                      ? null
                      : () => globalState.appController.updateProfile(profile),
                  supportUrl: headers['support-url'],
                ),
                const SizedBox(height: 18),
                if (hasSub) ...[
                  _TrafficCard(sub: sub),
                  const SizedBox(height: 12),
                ],
                if (showBuy) ...[
                  _BuyButtons(
                    showBuyPlan: showBuyPlan,
                    showBuyTraffic: showBuyTraffic,
                    buyPlanUrl: buyPlanUrl,
                    buyTrafficUrl: buyTrafficUrl,
                  ),
                  const SizedBox(height: 12),
                ],
                _ServerPanel(
                  serverName: serverName,
                  displayName: displayName,
                  nameCountryCode: nameCountryCode,
                  testUrl: testUrl,
                  otherCodes: otherCodes,
                  otherLocations: otherLocations,
                ),
              ],
            ),
          ),
          ),
        ),
        // Pinned to the bottom of the hero, just above the nav bar.
        const _ErrorHint(),
        const SizedBox(height: 14),
        Stack(
          clipBehavior: Clip.none,
          children: [
            _ConnectButton(isReady: isReady, protectedName: displayName),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 54 + 12,
              child: IgnorePointer(child: _ProtectedToast()),
            ),
          ],
        ),
      ],
    );
  }
}

// ----------------------------------------------------------------------------
// Logo
// ----------------------------------------------------------------------------
class _Logo extends StatelessWidget {
  const _Logo({this.logoUrl});

  final String? logoUrl;

  @override
  Widget build(BuildContext context) {
    const size = 104.0;
    final fallback = ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: Image.asset('assets/images/icon.png', width: size, height: size, fit: BoxFit.cover),
    );
    if (logoUrl == null || logoUrl!.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: logoUrl!.toLowerCase().endsWith('.svg')
          ? SvgPicture.network(logoUrl!, width: size, height: size,
              placeholderBuilder: (_) => fallback)
          : CachedNetworkImage(
              imageUrl: logoUrl!,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => fallback,
            ),
    );
  }
}

// ----------------------------------------------------------------------------
// Traffic card (usage bar + amount + days left)
// ----------------------------------------------------------------------------
class _TrafficCard extends StatelessWidget {
  const _TrafficCard({required this.sub});

  final SubscriptionInfo sub;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final used = (sub.upload + sub.download).toInt();
    final total = sub.total;
    final unlimited = total <= 0;
    final progress = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    final barColor = progress > 0.9
        ? Colors.red.shade400
        : progress > 0.7
            ? Colors.orange.shade400
            : colorScheme.primary;

    int? daysLeft;
    if (sub.expire > 0) {
      daysLeft = DateTime.fromMillisecondsSinceEpoch(sub.expire * 1000)
          .difference(DateTime.now())
          .inDays;
      if (daysLeft < 0) daysLeft = 0;
    }

    final daysUrgent = daysLeft != null && daysLeft <= 3;
    final daysColor = daysUrgent ? Colors.red.shade400 : colorScheme.primary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
        border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: RollingText(
                      unlimited
                          ? _formatBytes(used)
                          : '${_formatBytes(used)} / ${_formatBytes(total)}',
                      style: context.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontFamily: FontFamily.jetBrainsMono.value,
                      ),
                    ),
                  ),
                ),
              ),
              if (daysLeft != null) ...[
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: daysColor.withValues(alpha: 0.14),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.event_rounded, size: 14, color: daysColor),
                      const SizedBox(width: 5),
                      Text(
                        '${appLocalizations.remaining} $daysLeft ${_daysWord(daysLeft)}',
                        style: context.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: daysColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          if (!unlimited) ...[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                children: [
                  Container(height: 9, color: colorScheme.surfaceContainerHighest),
                  FractionallySizedBox(
                    widthFactor: progress <= 0 ? 0.0 : progress,
                    child: Container(
                      height: 9,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        gradient: LinearGradient(
                          colors: [barColor.withValues(alpha: 0.7), barColor],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// Buy / renew buttons (shown under the traffic card)
// ----------------------------------------------------------------------------
class _BuyButtons extends StatelessWidget {
  const _BuyButtons({
    required this.showBuyPlan,
    required this.showBuyTraffic,
    required this.buyPlanUrl,
    required this.buyTrafficUrl,
  });

  final bool showBuyPlan;
  final bool showBuyTraffic;
  final String? buyPlanUrl;
  final String? buyTrafficUrl;

  @override
  Widget build(BuildContext context) {
    final plan = _HeroBuyButton(
      icon: Icons.autorenew_rounded,
      label: 'Продлить подписку',
      filled: true,
      onTap: () => globalState.openUrl(buyPlanUrl!),
    );
    final traffic = _HeroBuyButton(
      icon: Icons.add_rounded,
      label: 'Докупить трафик',
      filled: false,
      onTap: () => globalState.openUrl(buyTrafficUrl!),
    );

    // Both triggers -> side by side, one each; a single trigger -> full width.
    if (showBuyPlan && showBuyTraffic) {
      return Row(
        children: [
          Expanded(child: plan),
          const SizedBox(width: 10),
          Expanded(child: traffic),
        ],
      );
    }
    if (showBuyPlan) return plan;
    if (showBuyTraffic) return traffic;
    return const SizedBox.shrink();
  }
}

class _HeroBuyButton extends StatelessWidget {
  const _HeroBuyButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = true,
    this.autofocus = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool filled;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final bg = filled
        ? colorScheme.primary
        : colorScheme.surfaceContainerHigh.withValues(alpha: 0.6);
    final fg = filled ? colorScheme.onPrimary : colorScheme.primary;
    return _FocusableTap(
      borderRadius: 16,
      autofocus: autofocus,
      onTap: onTap,
      child: Container(
        width: double.infinity,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: bg,
          border: filled
              ? null
              : Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: fg),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.textTheme.titleSmall
                    ?.copyWith(color: fg, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// Server panel (flag / host / ip / ping) — tap to change server
// ----------------------------------------------------------------------------
class _ServerPanel extends ConsumerWidget {
  const _ServerPanel({
    required this.serverName,
    required this.displayName,
    required this.nameCountryCode,
    required this.testUrl,
    this.otherCodes = const [],
    this.otherLocations = 0,
  });

  final String serverName;
  final String displayName;
  final String? nameCountryCode;
  final String? testUrl;
  final List<String> otherCodes;
  final int otherLocations;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = context.colorScheme;
    // select(!=null): the hero card only needs the connected/disconnected boolean,
    // so watching the raw runTime rebuilt the entire card (flags, traffic, server
    // panel, buy buttons, announce) every second. The elapsed-time text lives in
    // _ConnectButton, which intentionally keeps watching the value.
    final isConnected =
        ref.watch(runTimeProvider.select((value) => value != null));
    final delay = serverName.isNotEmpty
        ? ref.watch(getDelayProvider(proxyName: serverName, testUrl: testUrl))
        : null;

    return ValueListenableBuilder(
      valueListenable: detectionState.state,
      builder: (_, networkState, __) {
        final ipInfo = networkState.ipInfo;
        // Prefer the flag carried in the server name; fall back to the detected
        // exit-IP country, then a globe.
        final code = nameCountryCode ?? ipInfo?.countryCode ?? '';
        final flag = _countryCodeToEmoji(code);
        final title = displayName.isNotEmpty ? displayName : '—';

        return _FocusableTap(
          borderRadius: 18,
          onTap: () => globalState.appController.toPage(PageLabel.proxies),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
              border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
            ),
            // Country change: the old card content fades/slides out, the new
            // one in (keyed by the selected server).
            child: AnimatedSwitcher(
              duration: _reduceMotion(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 380),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.18),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              child: Row(
              key: ValueKey(serverName),
              children: [
                _FlagCircle(
                  countryCode: code,
                  fallbackEmoji: flag,
                  otherCodes: otherCodes,
                  stackCount: otherLocations,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      // IP line: hidden while the tunnel is off. Once connected:
                      // the real IP when known; a spinner + "determining IP" while
                      // actively resolving; a muted dash if resolution finished
                      // without an IP (failed / timed out).
                      if (isConnected) ...[
                        const SizedBox(height: 3),
                        if (ipInfo != null)
                          Text(
                            ipInfo.ip,
                            style: context.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              fontFamily: FontFamily.jetBrainsMono.value,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        else if (networkState.isTesting || networkState.isLoading)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.6,
                                  color: colorScheme.primary,
                                ),
                              ),
                              const SizedBox(width: 7),
                              Text(
                                appLocalizations.determiningIp,
                                style: context.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          )
                        else
                          Text(
                            '—',
                            style: context.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              fontFamily: FontFamily.jetBrainsMono.value,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                // Fixed width so the bars + ms text stay horizontally centred and
                // don't drift as the delay text width changes.
                SizedBox(
                  width: 46,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _SignalBars(delay: delay, serverName: serverName),
                      if (delay != null && delay > 0) ...[
                        const SizedBox(height: 3),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: RollingText(
                            '$delay ms',
                            style: context.textTheme.labelSmall?.copyWith(
                              color: utils.getDelayColor(delay) ?? colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                              fontFamily: FontFamily.jetBrainsMono.value,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // Chevron: signals the panel is tappable (drill into the server list).
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
            ),
          ),
        );
      },
    );
  }
}

// Large circle filled with the country flag (cropped to a circle; falls back to the
// flag emoji / globe). When the group has other locations, a couple of neutral
// theme-coloured discs peek out from behind it as a tidy "stack" affordance.
class _FlagCircle extends StatelessWidget {
  const _FlagCircle({
    required this.countryCode,
    required this.fallbackEmoji,
    this.otherCodes = const [],
    this.stackCount = 0,
  });

  final String countryCode;
  final String fallbackEmoji;
  final List<String> otherCodes;
  final int stackCount;

  @override
  Widget build(BuildContext context) {
    const size = 52.0;
    final colorScheme = context.colorScheme;
    final cc = countryCode.trim().toLowerCase();

    Widget fallback() => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colorScheme.surfaceContainerHighest,
          ),
          alignment: Alignment.center,
          child: EmojiText(fallbackEmoji, style: const TextStyle(fontSize: size * 0.5)),
        );

    final active = cc.length != 2
        ? fallback()
        : ClipOval(
            child: CachedNetworkImage(
              imageUrl: 'https://flagcdn.com/w160/$cc.png',
              width: size,
              height: size,
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(
                width: size,
                height: size,
                color: colorScheme.surfaceContainerHighest,
              ),
              errorWidget: (_, __, ___) => fallback(),
            ),
          );

    // Up to two of the group's other-location flags peek straight up from behind the
    // active one — smaller, ringed in the surface colour, and progressively darkened
    // the further back they sit, so they read as a centred stack receding into depth.
    final backs = otherCodes.take(2).toList();
    Widget backFlag(int i, String code) {
      final s = size * (1 - 0.14 * i);
      return Transform.translate(
        offset: Offset(0, -10.0 * i),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: colorScheme.surface, width: 1.5),
          ),
          child: ClipOval(
            child: Stack(
              children: [
                CachedNetworkImage(
                  imageUrl: 'https://flagcdn.com/w80/${code.toLowerCase()}.png',
                  width: s,
                  height: s,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => SizedBox(width: s, height: s),
                  errorWidget: (_, __, ___) => Container(
                    width: s,
                    height: s,
                    color: colorScheme.surfaceContainerHighest,
                  ),
                ),
                // Depth scrim: deeper cards are darker.
                Positioned.fill(
                  child: ColoredBox(color: Colors.black.withValues(alpha: 0.15 * i)),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final badge = stackCount <= 0
        ? null
        : Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              color: colorScheme.primary,
              border: Border.all(color: colorScheme.surface, width: 1.5),
            ),
            child: Text(
              '+$stackCount',
              style: context.textTheme.labelSmall?.copyWith(
                color: colorScheme.onPrimary,
                fontWeight: FontWeight.w700,
                fontFamily: FontFamily.jetBrainsMono.value,
              ),
            ),
          );

    // The active flag with its peeking back-flags and corner badge, as one 52px unit.
    final unit = Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        for (var i = backs.length; i >= 1; i--) backFlag(i, backs[i - 1]),
        active,
        if (badge != null) Positioned(right: -3, bottom: -3, child: badge),
      ],
    );

    // Reserve headroom matching how far the deepest back-flag sticks up (plus a little
    // for the badge), so the *whole* construction — not just the active flag — is
    // vertically centred in the row.
    final topPeek = backs.isEmpty
        ? 0.0
        : (10.0 * backs.length + size * (1 - 0.14 * backs.length) / 2 - size / 2 + 2)
            .clamp(0.0, 40.0)
            .toDouble();
    final bottomPeek = badge != null ? 7.0 : 0.0;

    if (topPeek == 0 && bottomPeek == 0) {
      return SizedBox(width: size, height: size, child: unit);
    }
    return SizedBox(
      width: size,
      height: size + topPeek + bottomPeek,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(top: topPeek, left: 0, width: size, height: size, child: unit),
        ],
      ),
    );
  }
}

// Mobile-network-style signal bars representing ping quality. The bars fill up
// one after another whenever the server or its quality level changes.
class _SignalBars extends StatelessWidget {
  const _SignalBars({required this.delay, this.serverName = ''});

  final int? delay;
  final String serverName;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final dim = colorScheme.onSurfaceVariant.withValues(alpha: 0.25);

    final int level;
    final Color color;
    if (delay == null || delay == 0) {
      level = 0;
      color = dim;
    } else if (delay! < 0) {
      level = 0;
      color = Colors.red.shade400;
    } else {
      color = utils.getDelayColor(delay) ?? Colors.green;
      level = delay! < 150
          ? 4
          : delay! < 300
              ? 3
              : delay! < 600
                  ? 2
                  : 1;
    }

    const heights = [9.0, 13.0, 17.0, 21.0];
    Widget bars(double filled) => Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(4, (i) {
            final f = (filled - i).clamp(0.0, 1.0);
            return Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : 3),
              child: Container(
                width: 4,
                height: heights[i],
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  color: Color.lerp(dim, color, f),
                ),
              ),
            );
          }),
        );

    if (_reduceMotion(context) || level == 0) return bars(level.toDouble());
    return TweenAnimationBuilder<double>(
      key: ValueKey('$serverName|$level'),
      tween: Tween(begin: 0, end: level.toDouble()),
      duration: Duration(milliseconds: 160 * level + 200),
      curve: Curves.easeOut,
      builder: (_, value, __) => bars(value),
    );
  }
}

// ----------------------------------------------------------------------------
// Logo rings — soft rings expand from the logo while connecting
// ----------------------------------------------------------------------------
class _LogoWithRings extends ConsumerStatefulWidget {
  const _LogoWithRings({required this.child});

  final Widget child;

  @override
  ConsumerState<_LogoWithRings> createState() => _LogoWithRingsState();
}

class _LogoWithRingsState extends ConsumerState<_LogoWithRings>
    with TickerProviderStateMixin {
  // Outward rings while connecting.
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );
  // Rings collapsing back into the logo on disconnect (one shot).
  late final AnimationController _inward = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 750),
  )..addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) setState(() {});
    });
  bool _reduce = false;

  @override
  void initState() {
    super.initState();
    _heroConnecting.addListener(_sync);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduce = _reduceMotion(context);
    _apply();
  }

  void _apply() {
    final on = _heroConnecting.value && !_reduce;
    if (on && !_c.isAnimating) {
      _c.repeat();
    } else if (!on && _c.isAnimating) {
      _c
        ..stop()
        ..reset();
    }
  }

  void _sync() {
    if (!mounted) return;
    _apply();
    setState(() {});
  }

  @override
  void dispose() {
    _heroConnecting.removeListener(_sync);
    _c.dispose();
    _inward.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(runTimeProvider.select((value) => value != null),
        (prev, next) {
      if (prev == true && !next && !_reduce) {
        _inward.forward(from: 0);
        setState(() {});
      }
    });
    final connected =
        ref.watch(runTimeProvider.select((value) => value != null));
    final color = context.colorScheme.primary;
    return SizedBox(
      width: 104,
      height: 104,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          if (_c.isAnimating)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _c,
                  builder: (_, __) => CustomPaint(
                    painter: _RingsPainter(t: _c.value, color: color),
                  ),
                ),
              ),
            ),
          if (_inward.isAnimating)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _inward,
                  builder: (_, __) => CustomPaint(
                    painter:
                        _InwardRingsPainter(t: _inward.value, color: color),
                  ),
                ),
              ),
            ),
          // Slightly dimmed while idle: "lights up" when the tunnel is on.
          AnimatedOpacity(
            opacity: connected || _heroConnecting.value ? 1 : 0.82,
            duration: const Duration(milliseconds: 500),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}

class _InwardRingsPainter extends CustomPainter {
  _InwardRingsPainter({required this.t, required this.color});

  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    for (var i = 0; i < 3; i++) {
      final p = ((t - i * 0.12) / 0.76).clamp(0.0, 1.0);
      if (p <= 0 || p >= 1) continue;
      final scale = 1.9 - 0.9 * Curves.easeInCubic.transform(p);
      final alpha = 0.7 * math.sin(p * math.pi);
      final rect = Rect.fromCenter(
        center: center,
        width: size.width * scale,
        height: size.height * scale,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(26 * scale)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_InwardRingsPainter oldDelegate) =>
      oldDelegate.t != t || oldDelegate.color != color;
}

class _RingsPainter extends CustomPainter {
  _RingsPainter({required this.t, required this.color});

  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1.0;
      final scale = 1 + 0.9 * Curves.easeOut.transform(p);
      final alpha = 0.55 * (1 - p) * (1 - p);
      final rect = Rect.fromCenter(
        center: center,
        width: size.width * scale,
        height: size.height * scale,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(26 * scale)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_RingsPainter oldDelegate) =>
      oldDelegate.t != t || oldDelegate.color != color;
}

// ----------------------------------------------------------------------------
// "Protected · country" toast above the connect button
// ----------------------------------------------------------------------------
class _ProtectedToast extends StatelessWidget {
  const _ProtectedToast();

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    const ok = Color(0xFF5BD68A);
    return ValueListenableBuilder<String?>(
      valueListenable: _heroToast,
      builder: (_, text, __) {
        final visible = text != null;
        return AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(0, 0.4),
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: ok.withValues(alpha: 0.45)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.shield_rounded, size: 18, color: ok),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        text ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ----------------------------------------------------------------------------
// Connect button — press, "connecting" shimmer, then the time counter
// ----------------------------------------------------------------------------
class _ConnectButton extends ConsumerStatefulWidget {
  const _ConnectButton({required this.isReady, this.protectedName = ''});

  final bool isReady;
  final String protectedName;

  @override
  ConsumerState<_ConnectButton> createState() => _ConnectButtonState();
}

class _ConnectButtonState extends ConsumerState<_ConnectButton>
    with TickerProviderStateMixin {
  late final AnimationController _shimmer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );
  // Short horizontal shake when connecting failed.
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480),
  );
  // Soft pulsing halo after the first subscription was added ("press me").
  late final AnimationController _glow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _heroConnecting.addListener(_onConnecting);
    _heroError.addListener(_onFlags);
    _heroDone.addListener(_onDone);
  }

  @override
  void dispose() {
    _heroConnecting.removeListener(_onConnecting);
    _heroError.removeListener(_onFlags);
    _heroDone.removeListener(_onDone);
    _shimmer.dispose();
    _shake.dispose();
    _glow.dispose();
    super.dispose();
  }

  void _onConnecting() {
    if (!mounted) return;
    if (_heroConnecting.value && !_reduceMotion(context)) {
      _shimmer.repeat();
    } else {
      _shimmer
        ..stop()
        ..reset();
    }
    setState(() {});
  }

  void _onFlags() {
    if (mounted) setState(() {});
  }

  void _onDone() {
    if (!mounted) return;
    if (_heroDone.value && !_reduceMotion(context)) {
      _glow.repeat();
    } else {
      _glow
        ..stop()
        ..reset();
    }
    setState(() {});
  }

  void _setPressed(bool value) {
    if (_pressed != value && mounted) setState(() => _pressed = value);
  }

  Future<void> _toggle(bool isStart) async {
    if (_heroConnecting.value) return;
    _setHeroError(false);
    _heroDone.value = false;
    if (Platform.isAndroid) {
      HapticFeedback.mediumImpact();
    }
    if (isStart) {
      await globalState.appController.updateStatus(false);
      return;
    }
    _heroConnecting.value = true;
    final began = DateTime.now();
    Future<void> attempt() async {
      try {
        await globalState.appController
            .updateStatus(true)
            .timeout(const Duration(seconds: 30));
      } catch (_) {
        // Errors are surfaced by the controller itself.
      }
    }

    await attempt();
    var coreOk = true;
    if (mounted && ref.read(runTimeProvider) == null) {
      // Failed: if the core isn't running at all, restart it once and retry
      // before bothering the user.
      coreOk = await _coreAlive();
      if (!coreOk) {
        try {
          await globalState.appController
              .restartCore()
              .timeout(const Duration(seconds: 20));
        } catch (_) {}
        coreOk = await _coreAlive();
        if (coreOk) await attempt();
      }
    }
    // Keep the "connecting" state on screen long enough to be read.
    const minShow = Duration(milliseconds: 900);
    final spent = DateTime.now().difference(began);
    if (spent < minShow) await Future<void>.delayed(minShow - spent);
    _heroConnecting.value = false;
    if (!mounted) return;
    if (ref.read(runTimeProvider) == null) {
      // Bring-up failed: shake, turn red and explain what to do.
      _setHeroError(true, core: !coreOk);
      if (!_reduceMotion(context)) _shake.forward(from: 0);
      if (Platform.isAndroid) {
        HapticFeedback.heavyImpact();
      }
      return;
    }
    final name = widget.protectedName.trim();
    final word = _isEn ? 'Protected' : 'Защищено';
    _showHeroToast(name.isEmpty ? word : '$word · $name');
    if (Platform.isAndroid) {
      HapticFeedback.vibrate();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final runTime = ref.watch(runTimeProvider);
    final isStart = runTime != null;
    final connecting = _heroConnecting.value && !isStart;
    final failed = _heroError.value && !isStart && !connecting;
    final isReady = widget.isReady;

    final Color bg;
    final Color fg;
    Border? border;
    if (!isReady) {
      bg = colorScheme.surfaceContainerHighest.withValues(alpha: 0.5);
      fg = colorScheme.onSurface.withValues(alpha: 0.38);
    } else if (connecting) {
      bg = Color.lerp(colorScheme.primary, colorScheme.surface, 0.72)!;
      fg = Color.lerp(colorScheme.primary, Colors.white, 0.45)!;
      border = Border.all(color: colorScheme.primary.withValues(alpha: 0.45));
    } else if (failed) {
      bg = const Color(0xFFC62828);
      fg = Colors.white;
    } else if (isStart) {
      bg = colorScheme.surfaceContainerHigh.withValues(alpha: 0.8);
      fg = colorScheme.primary;
      border = Border.all(color: colorScheme.primary.withValues(alpha: 0.4));
    } else {
      bg = colorScheme.primary;
      fg = colorScheme.onPrimary;
    }

    final labelStyle = context.textTheme.titleSmall?.copyWith(
      color: fg,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.3,
    );
    final Widget content;
    if (connecting) {
      content = Text(
        _isEn ? 'Connecting…' : 'Подключение…',
        key: const ValueKey('connecting'),
        style: labelStyle,
      );
    } else if (failed) {
      content = Row(
        key: const ValueKey('failed'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.refresh_rounded, size: 20, color: fg),
          const SizedBox(width: 8),
          Text(_isEn ? 'Try again' : 'Попробовать снова', style: labelStyle),
        ],
      );
    } else if (isStart) {
      content = RollingText(
        utils.getTimeText(runTime),
        key: const ValueKey('on'),
        style: context.textTheme.titleSmall?.copyWith(
          color: fg,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          fontFamily: FontFamily.jetBrainsMono.value,
        ),
      );
    } else {
      content = Icon(
        Icons.play_arrow_rounded,
        key: const ValueKey('off'),
        size: 30,
        color: fg,
      );
    }

    final button = AnimatedScale(
      scale: _pressed ? 0.96 : 1,
      duration: const Duration(milliseconds: 120),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: double.infinity,
        height: 54,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          color: bg,
          border: border,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(23),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (connecting && _shimmer.isAnimating)
                AnimatedBuilder(
                  animation: _shimmer,
                  builder: (_, __) => FractionalTranslation(
                    translation: Offset(-1 + 2 * _shimmer.value, 0),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.white.withValues(alpha: 0),
                            Colors.white.withValues(alpha: 0.16),
                            Colors.white.withValues(alpha: 0),
                          ],
                          stops: const [0.3, 0.5, 0.7],
                        ),
                      ),
                    ),
                  ),
                ),
              Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale:
                          Tween<double>(begin: 0.8, end: 1).animate(animation),
                      child: child,
                    ),
                  ),
                  child: content,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return _FocusableTap(
      autofocus: true,
      borderRadius: 24,
      onTap: isReady ? () => _toggle(isStart) : null,
      child: Listener(
        onPointerDown: (_) => _setPressed(isReady),
        onPointerUp: (_) => _setPressed(false),
        onPointerCancel: (_) => _setPressed(false),
        child: AnimatedBuilder(
          animation: Listenable.merge([_shake, _glow]),
          builder: (_, child) {
            final s = _shake.value;
            final dx = _shake.isAnimating
                ? math.sin(s * math.pi * 6) * 9 * (1 - s)
                : 0.0;
            final g = _glow.isAnimating ? math.sin(_glow.value * math.pi) : 0.0;
            return Transform.translate(
              offset: Offset(dx, 0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: g > 0
                      ? [
                          BoxShadow(
                            color: colorScheme.primary
                                .withValues(alpha: 0.4 * g),
                            spreadRadius: 7 * g,
                          ),
                        ]
                      : null,
                ),
                child: child,
              ),
            );
          },
          child: button,
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// "Couldn't connect" hint above the button
// ----------------------------------------------------------------------------
class _ErrorHint extends StatelessWidget {
  const _ErrorHint();

  @override
  Widget build(BuildContext context) {
    final en = _isEn;
    return AnimatedBuilder(
      animation: Listenable.merge([_heroError, _heroCoreProblem]),
      builder: (context, _) {
        final visible = _heroError.value;
        final core = _heroCoreProblem.value;
        final String title;
        final String text;
        if (core && Platform.isAndroid) {
          title = en
              ? 'The phone is blocking Tunnexo'
              : 'Телефон не даёт Tunnexo работать';
          text = en
              ? 'Allow Tunnexo to run in the background: turn off battery '
                  'restrictions and enable autostart, then tap the button again.'
              : 'Разрешите Tunnexo работать в фоне: снимите ограничения '
                  'батареи и включите автозапуск, затем нажмите кнопку ещё раз.';
        } else if (core) {
          title = en
              ? 'The VPN core did not start'
              : 'Не удалось запустить ядро VPN';
          text = en
              ? 'Quit Tunnexo from the tray icon, open it again and tap '
                  'the button.'
              : 'Закройте Tunnexo через значок в трее, откройте снова '
                  'и нажмите кнопку.';
        } else {
          title = en ? 'Could not connect' : 'Не удалось подключиться';
          text = en
              ? 'Check your internet and tap the button again. '
                  'Still failing — tap “Update” or pick another country.'
              : 'Проверьте интернет и нажмите кнопку ещё раз. '
                  'Не помогает — нажмите «Обновить» или выберите другую страну.';
        }

        final card = Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: const Color(0xF25A1010),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: const Color(0xFFEF5350).withValues(alpha: 0.55)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline_rounded,
                  size: 22, color: Color(0xFFFF8A80)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: context.textTheme.titleSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      text,
                      style: context.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFFF3D2C8),
                        height: 1.4,
                      ),
                    ),
                    if (core && Platform.isAndroid) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _HintAction(
                            icon: Icons.battery_charging_full_rounded,
                            label: en ? 'Battery' : 'Батарея',
                            onTap: () => app_plugin.app
                                ?.requestIgnoreBatteryOptimizations(),
                          ),
                          _HintAction(
                            icon: Icons.play_circle_outline_rounded,
                            label: en ? 'Autostart' : 'Автозапуск',
                            onTap: () =>
                                app_plugin.app?.openAutoStartSettings(),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );

        return AnimatedSize(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          alignment: Alignment.bottomCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.15),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: visible
                ? KeyedSubtree(
                    key: ValueKey('hint-$core'),
                    child: card,
                  )
                : const SizedBox(width: double.infinity),
          ),
        );
      },
    );
  }
}

class _HintAction extends StatelessWidget {
  const _HintAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => _FocusableTap(
        borderRadius: 18,
        onTap: onTap,
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: Colors.white),
              const SizedBox(width: 6),
              Text(
                label,
                style: context.textTheme.labelLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      );
}

// ----------------------------------------------------------------------------
// "Done!" after the first subscription was added
// ----------------------------------------------------------------------------
class _DoneSwitch extends StatefulWidget {
  const _DoneSwitch({required this.child});

  final Widget child;

  @override
  State<_DoneSwitch> createState() => _DoneSwitchState();
}

class _DoneSwitchState extends State<_DoneSwitch> {
  bool _show = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final at = globalState.firstProfileAddedAt.value;
    if (at != null &&
        DateTime.now().difference(at) < const Duration(seconds: 5)) {
      _show = true;
      _arm();
    }
    globalState.firstProfileAddedAt.addListener(_onAdded);
  }

  void _onAdded() {
    if (!mounted || globalState.firstProfileAddedAt.value == null) return;
    setState(() => _show = true);
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 3800), _hide);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_show) _heroDone.value = true;
    });
  }

  void _hide() {
    _timer?.cancel();
    if (mounted && _show) setState(() => _show = false);
    // Keep the button halo a little longer than the "Done!" card.
    Timer(const Duration(milliseconds: 2400), () => _heroDone.value = false);
  }

  @override
  void dispose() {
    _timer?.cancel();
    globalState.firstProfileAddedAt.removeListener(_onAdded);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _heroDone.value = false;
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 450),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (current, previous) => Stack(
          fit: StackFit.expand,
          children: [...previous, if (current != null) current],
        ),
        child: _show
            ? GestureDetector(
                key: const ValueKey('done'),
                behavior: HitTestBehavior.opaque,
                onTap: _hide,
                child: const _DoneView(),
              )
            : KeyedSubtree(key: const ValueKey('main'), child: widget.child),
      );
}

class _DoneView extends StatefulWidget {
  const _DoneView();

  @override
  State<_DoneView> createState() => _DoneViewState();
}

class _DoneViewState extends State<_DoneView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.isAnimating || _c.value > 0) return;
    if (_reduceMotion(context)) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final en = _isEn;
    return Center(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          double seg(double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);
          final title = Curves.easeOut.transform(seg(0.5, 0.75));
          final sub = Curves.easeOut.transform(seg(0.62, 0.88));
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CustomPaint(
                size: const Size(132, 132),
                painter: _CheckPainter(
                  t: t,
                  ring: colorScheme.primary,
                  tick: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 18),
              Opacity(
                opacity: title,
                child: Transform.translate(
                  offset: Offset(0, 12 * (1 - title)),
                  child: Text(
                    en ? 'Done!' : 'Готово!',
                    style: context.textTheme.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Opacity(
                opacity: sub,
                child: Transform.translate(
                  offset: Offset(0, 12 * (1 - sub)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      en
                          ? 'Subscription added — tap the connect button'
                          : 'Подписка добавлена — нажмите кнопку подключения',
                      textAlign: TextAlign.center,
                      style: context.textTheme.bodyLarge?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  _CheckPainter({required this.t, required this.ring, required this.tick});

  final double t;
  final Color ring;
  final Color tick;

  static double _seg(double t, double a, double b) =>
      ((t - a) / (b - a)).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 120;
    canvas.save();
    canvas.scale(s);
    const c = Offset(60, 60);
    final pop = Curves.easeOutBack.transform(_seg(t, 0.15, 0.4));
    if (pop > 0) {
      canvas.drawCircle(
          c, 54 * pop, Paint()..color = ring.withValues(alpha: 0.16));
    }
    final arc = Curves.easeOutCubic.transform(_seg(t, 0.0, 0.35));
    if (arc > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: 52),
        -math.pi / 2,
        2 * math.pi * arc,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..strokeCap = StrokeCap.round
          ..color = ring,
      );
    }
    final k = Curves.easeOutCubic.transform(_seg(t, 0.32, 0.6));
    if (k > 0) {
      final path = Path()
        ..moveTo(38, 62)
        ..lineTo(54, 78)
        ..lineTo(84, 46);
      final metric = path.computeMetrics().first;
      canvas.drawPath(
        metric.extractPath(0, metric.length * k),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = tick,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CheckPainter oldDelegate) => oldDelegate.t != t;
}

// ----------------------------------------------------------------------------
// Empty state (no profile) — welcome + three steps
// ----------------------------------------------------------------------------
class _EmptyHero extends StatelessWidget {
  const _EmptyHero();

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final en = _isEn;
    final steps = en
        ? const [
            'Get a subscription in the Telegram bot',
            'In the bot tap “Connect” → “Add to Tunnexo”',
            'Tap the big connect button',
          ]
        : const [
            'Оформите подписку в Telegram-боте',
            'Нажмите в боте «Подключиться» → «Добавить в Tunnexo»',
            'Нажмите большую кнопку подключения',
          ];
    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 8),
          const _Logo(),
          const SizedBox(height: 16),
          Text(
            en ? 'Welcome!' : 'Добро пожаловать!',
            textAlign: TextAlign.center,
            style: context.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            en
                ? 'Setup takes a couple of minutes'
                : 'Подключение займёт пару минут',
            textAlign: TextAlign.center,
            style: context.textTheme.bodyMedium
                ?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
              border: Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
            ),
            child: Column(
              children: [
                for (var i = 0; i < steps.length; i++)
                  _OnboardStep(number: i + 1, text: steps[i]),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _HeroBuyButton(
            icon: Icons.send_rounded,
            label: en ? 'Open the bot' : 'Открыть бота',
            autofocus: true,
            onTap: () => _launchExternal(tunnexoBotUrl),
          ),
          const SizedBox(height: 10),
          _HeroBuyButton(
            icon: Icons.link_rounded,
            label: en ? 'Paste a link manually' : 'Вставить ссылку вручную',
            filled: false,
            onTap: () async {
              final url = await globalState.showCommonDialog<String>(
                child: const URLFormDialog(),
              );
              if (url != null) {
                globalState.appController.addProfileFormURL(url);
              }
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _OnboardStep extends StatelessWidget {
  const _OnboardStep({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colorScheme.primary.withValues(alpha: 0.16),
            ),
            child: Text(
              '$number',
              style: context.textTheme.labelLarge?.copyWith(
                color: colorScheme.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: context.textTheme.bodyMedium?.copyWith(height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _AnnounceBanner extends StatelessWidget {
  const _AnnounceBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: colorScheme.secondaryContainer,
      ),
      // EmojiText (not Text): renders flag/emoji runs with the Twemoji font so
      // they show up — plain Text drops country flags entirely on Windows.
      child: EmojiText(
        text,
        style: context.textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSecondaryContainer,
          height: 1.4,
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// Hero actions: refresh / support chips
// ----------------------------------------------------------------------------
class _HeroActionRow extends ConsumerWidget {
  const _HeroActionRow({
    required this.isUpdating,
    required this.onUpdate,
    this.supportUrl,
  });

  final bool isUpdating;
  final VoidCallback? onUpdate;
  final String? supportUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasSupport = supportUrl != null && supportUrl!.isNotEmpty;
    final globalModeEnabled = ref.watch(globalModeEnabledProvider);
    return Row(
      children: [
        Expanded(
          child: _ActionChip(
            icon: Icons.refresh_rounded,
            label: appLocalizations.update,
            busy: isUpdating,
            onTap: onUpdate,
          ),
        ),
        if (hasSupport) ...[
          const SizedBox(width: 10),
          Expanded(
            child: _ActionChip(
              icon: Icons.support_agent_rounded,
              label: appLocalizations.support,
              onTap: () => globalState.openUrl(supportUrl!),
            ),
          ),
        ],
        if (globalModeEnabled) ...[
          const SizedBox(width: 10),
          const _ModeChip(),
        ],
      ],
    );
  }
}

// Outbound-mode chip (rule/global) — icon-only square in the action-chip visual
// language, pinned after the Support chip. The current mode is conveyed by the
// icon itself; tapping opens the same mode popup as on the proxies page. Only
// rendered when the global-mode setting is on (gated by the caller).
class _ModeChip extends ConsumerWidget {
  const _ModeChip();

  IconData _modeIcon(Mode mode) => switch (mode) {
        Mode.rule => Icons.rule,
        Mode.global => Icons.public,
        Mode.direct => Icons.flash_on,
      };

  String _modeLabel(Mode mode) => switch (mode) {
        Mode.rule => appLocalizations.rule,
        Mode.global => appLocalizations.global,
        Mode.direct => appLocalizations.direct,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = context.colorScheme;
    final mode = ref.watch(
      patchClashConfigProvider.select((state) => state.mode),
    );
    return CommonPopupBox(
      targetBuilder: (open) => Tooltip(
        message: _modeLabel(mode),
        child: _FocusableTap(
          borderRadius: 22,
          onTap: () => open(offset: const Offset(0, 20)),
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
            ),
            child: Icon(_modeIcon(mode), size: 18, color: colorScheme.primary),
          ),
        ),
      ),
      popup: CommonPopupMenu(
        items: [
          for (final item in Mode.values.where((m) => m != Mode.direct))
            PopupMenuItemData(
              icon: _modeIcon(item),
              label: _modeLabel(item),
              onPressed: () {
                globalState.appController.changeMode(item);
              },
            ),
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return _FocusableTap(
      borderRadius: 22,
      onTap: busy ? null : onTap,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: busy
                  ? CircularProgressIndicator(
                      strokeWidth: 2, color: colorScheme.primary)
                  : Icon(icon, size: 18, color: colorScheme.primary),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                style: context.textTheme.labelLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
