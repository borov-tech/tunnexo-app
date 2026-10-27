import 'package:flclashx/common/common.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/views/proxies/common.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ProxyCard extends StatelessWidget {

  const ProxyCard({
    super.key,
    required this.groupName,
    required this.testUrl,
    required this.proxy,
    required this.groupType,
    required this.type,
  });
  final String groupName;
  final Proxy proxy;
  final GroupType groupType;
  final ProxyCardType type;
  final String? testUrl;

  Measure get measure => globalState.measure;

  void _handleTestCurrentDelay() {
    proxyDelayTest(
      proxy,
      testUrl,
    );
  }

  Widget _buildDelayText() => SizedBox(
      height: measure.labelSmallHeight,
      child: Consumer(
        builder: (context, ref, __) {
          final delay = ref.watch(getDelayProvider(
            proxyName: proxy.name,
            testUrl: testUrl,
          ));
          final Widget value = delay == 0 || delay == null
              ? SizedBox(
                  height: measure.labelSmallHeight,
                  width: measure.labelSmallHeight,
                  child: delay == 0
                      ? const CircularProgressIndicator(
                          strokeWidth: 2,
                        )
                      : IconButton(
                          icon: const Icon(Icons.bolt),
                          iconSize: globalState.measure.labelSmallHeight,
                          padding: EdgeInsets.zero,
                          onPressed: _handleTestCurrentDelay,
                        ),
                )
              : GestureDetector(
                  onTap: _handleTestCurrentDelay,
                  child: Text(
                    delay > 0 ? '$delay ms' : "Timeout",
                    style: context.textTheme.labelSmall?.copyWith(
                      overflow: TextOverflow.ellipsis,
                      color: utils.getDelayColor(
                        delay,
                      ),
                    ),
                  ),
                );
          // The result pops in from below when a measurement finishes.
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            switchInCurve: Curves.easeOutCubic,
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.centerRight,
              children: [...previous, if (current != null) current],
            ),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.6),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: KeyedSubtree(
              key: ValueKey(delay == 0
                  ? 'testing'
                  : delay == null
                      ? 'none'
                      : 'value'),
              child: value,
            ),
          );
        },
      ),
    );

  Widget _buildProxyNameText(BuildContext context) {
    if (type == ProxyCardType.oneline) {
      return Consumer(
        builder: (context, ref, child) {
          final isSelected = groupType.isComputedSelected &&
              ref.watch(getProxyNameProvider(groupName)) == proxy.name;

          return Padding(
            padding:
                isSelected ? const EdgeInsets.only(right: 32) : EdgeInsets.zero,
            child: child,
          );
        },
        child: SizedBox(
          height: measure.bodyMediumHeight * 1,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(
                child: EmojiText(
                  proxy.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 8),
              _buildDelayText(),
            ],
          ),
        ),
      );
    } else if (type == ProxyCardType.min) {
      return SizedBox(
        height: measure.bodyMediumHeight * 1,
        child: EmojiText(
          proxy.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.textTheme.bodyMedium,
        ),
      );
    } else {
      return SizedBox(
        height: measure.bodyMediumHeight * 2,
        child: EmojiText(
          proxy.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: context.textTheme.bodyMedium,
        ),
      );
    }
  }

  Future<void> _changeProxy(WidgetRef ref) async {
    final isComputedSelected = groupType.isComputedSelected;
    final isSelector = groupType == GroupType.Selector;
    if (isComputedSelected || isSelector) {
      final currentProxyName = ref.read(getProxyNameProvider(groupName));
      final nextProxyName = switch (isComputedSelected) {
        true => currentProxyName == proxy.name ? "" : proxy.name,
        false => proxy.name,
      };
      final appController = globalState.appController;
      appController.updateCurrentSelectedMap(
        groupName,
        nextProxyName,
      );
      appController.changeProxyDebounce(groupName, nextProxyName);
      return;
    }
    globalState.showNotifier(
      appLocalizations.notSelectedTip,
    );
  }

  @override
  Widget build(BuildContext context) {
    final measure = globalState.measure;
    final delayText = _buildDelayText();
    final proxyNameText = _buildProxyNameText(context);
    return Stack(
      children: [
        Consumer(
          builder: (_, ref, child) {
            final selectedProxyName =
                ref.watch(getSelectedProxyNameProvider(groupName));
            return CommonCard(
              key: key,
              onPressed: () {
                _changeProxy(ref);
              },
              isSelected: selectedProxyName == proxy.name,
              child: child!,
            );
          },
          child: Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                proxyNameText,
                if (type != ProxyCardType.oneline) ...[
                  const SizedBox(
                    height: 8,
                  ),
                  if (type == ProxyCardType.expand) ...[
                    SizedBox(
                      height: measure.bodySmallHeight,
                      child: _ProxyDesc(
                        proxy: proxy,
                      ),
                    ),
                    const SizedBox(
                      height: 6,
                    ),
                    delayText,
                  ] else
                    SizedBox(
                      height: measure.bodySmallHeight,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Flexible(
                            flex: 1,
                            child: _ProxyDesc(proxy: proxy),
                          ),
                          delayText,
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        // Light wave sweeping over the card while its delay is being tested.
        Positioned.fill(
          child: IgnorePointer(
            child: Consumer(
              builder: (_, ref, __) {
                final delay = ref.watch(getDelayProvider(
                  proxyName: proxy.name,
                  testUrl: testUrl,
                ));
                return delay == 0
                    ? const _TestingSweep()
                    : const SizedBox.shrink();
              },
            ),
          ),
        ),
        if (groupType.isComputedSelected)
          Positioned(
            top: 0,
            right: 0,
            child: _ProxyComputedMark(
              groupName: groupName,
              proxy: proxy,
              cardType: type,
            ),
          )
      ],
    );
  }
}

class _ProxyDesc extends ConsumerWidget {

  const _ProxyDesc({
    required this.proxy,
  });
  final Proxy proxy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final desc = ref.watch(
      getProxyDescProvider(proxy),
    );
    return EmojiText(
      desc,
      overflow: TextOverflow.ellipsis,
      style: context.textTheme.bodySmall?.copyWith(
        color: context.textTheme.bodySmall?.color?.opacity80,
      ),
    );
  }
}

class _ProxyComputedMark extends ConsumerWidget {

  const _ProxyComputedMark({
    required this.groupName,
    required this.proxy,
    required this.cardType,
  });
  final String groupName;
  final Proxy proxy;
  final ProxyCardType cardType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final proxyName = ref.watch(
      getProxyNameProvider(groupName),
    );
    if (proxyName != proxy.name) {
      return const SizedBox();
    }

    final margin = cardType == ProxyCardType.oneline
        ? const EdgeInsets.fromLTRB(8, 4, 8, 8)
        : const EdgeInsets.all(8);

    return Container(
      alignment: Alignment.topRight,
      margin: margin,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Theme.of(context).colorScheme.secondaryContainer,
        ),
        child: const SelectIcon(),
      ),
    );
  }
}

// A soft highlight that sweeps across a proxy card while its delay is tested.
// All cards share one clock and are phase-shifted by their vertical position,
// so a list being tested shows a wave running from top to bottom.
class _TestingSweep extends StatefulWidget {
  const _TestingSweep();

  @override
  State<_TestingSweep> createState() => _TestingSweepState();
}

class _TestingSweepState extends State<_TestingSweep>
    with SingleTickerProviderStateMixin {
  static const _period = 1400;
  late final AnimationController _tick = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _period),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!reduce && !_tick.isAnimating) _tick.repeat();
  }

  @override
  void dispose() {
    _tick.dispose();
    super.dispose();
  }

  double _phase() {
    var dy = 0.0;
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize && box.attached) {
      dy = box.localToGlobal(Offset.zero).dy;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final t = (now % _period) / _period - dy / 900;
    return t - t.floorToDouble();
  }

  @override
  Widget build(BuildContext context) {
    if (!_tick.isAnimating) return const SizedBox.shrink();
    final color = context.colorScheme.primary;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AnimatedBuilder(
        animation: _tick,
        builder: (_, __) {
          final p = _phase();
          return FractionalTranslation(
            translation: Offset(-1.2 + 2.4 * p, 0),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    color.withValues(alpha: 0),
                    color.withValues(alpha: 0.16),
                    color.withValues(alpha: 0),
                  ],
                  stops: const [0.25, 0.5, 0.75],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
