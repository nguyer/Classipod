import 'dart:async';

import 'package:classipod/core/extensions/build_context_extensions.dart';
import 'package:classipod/core/navigation/routes.dart';
import 'package:classipod/core/sonos/sonos_controller.dart';
import 'package:classipod/core/theme/ipod_typography.dart';
import 'package:classipod/features/custom_screen_elements/custom_screen.dart';
import 'package:classipod/features/settings/widgets/settings_list_tile.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef _SonosRow = ({
  String title,
  String? value,
  Future<void> Function() action,
});

String sonosError(BuildContext context, String code) => switch (code) {
  'permission' => context.localization.sonosPermissionError,
  'notFound' => context.localization.sonosNotFound,
  'address' => context.localization.sonosAddressError,
  'serverTracksOnly' => context.localization.sonosServerTracksOnly,
  'serverAddress' => context.localization.sonosServerAddressError,
  'queueChanged' => context.localization.sonosQueueChanged,
  _ => context.localization.sonosConnectionError,
};

class SonosScreen extends ConsumerStatefulWidget {
  const SonosScreen({super.key});
  @override
  ConsumerState<SonosScreen> createState() => _SonosScreenState();
}

class _SonosScreenState extends ConsumerState<SonosScreen> with CustomScreen {
  List<_SonosRow> _rows = [];
  bool _handling = false;
  @override
  String get routeName => Routes.sonos.name;
  @override
  List<_SonosRow> get displayItems => _rows;
  @override
  bool get useScrollViewport => true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(sonosControllerProvider).rooms.isEmpty) {
        unawaited(ref.read(sonosControllerProvider.notifier).discover());
      }
    });
  }

  @override
  Future<void> onSelectPressed() => _select(selectedDisplayItem);
  Future<void> _select(int index) async {
    final state = ref.read(sonosControllerProvider);
    if (_handling || state.scanning || state.busy || index >= _rows.length) {
      return;
    }
    _handling = true;
    setState(() => selectedDisplayItem = index);
    try {
      await _rows[index].action();
    } finally {
      _handling = false;
    }
  }

  Future<bool> _confirm(String message) async =>
      await showCupertinoDialog<bool>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(context.localization.sonosTitle),
          content: Text(message),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(context.localization.cancelText),
            ),
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(context.localization.sonosContinue),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _addAddress() async {
    final input = TextEditingController();
    try {
      final value = await showCupertinoDialog<String>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(context.localization.sonosAddAddress),
          content: CupertinoTextField(
            controller: input,
            placeholder: '192.168.1.100',
            keyboardType: TextInputType.url,
            autocorrect: false,
            autofocus: true,
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.localization.cancelText),
            ),
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(input.text),
              child: Text(context.localization.sonosContinue),
            ),
          ],
        ),
      );
      if (value != null) {
        await ref.read(sonosControllerProvider.notifier).addAddress(value);
      }
    } finally {
      input.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sonosControllerProvider);
    final controller = ref.read(sonosControllerProvider.notifier);
    final l = context.localization;
    _rows = [
      (
        title: l.sonosThisPhone,
        value: state.selectedId == null ? l.sonosSelected : null,
        action: () => controller.selectRoom(null),
      ),
      (title: l.sonosDiscover, value: null, action: controller.discover),
      (title: l.sonosAddAddress, value: null, action: _addAddress),
      for (final room in state.rooms.where((room) => room.visible))
        (
          title: room.name,
          value: room.id == state.selectedId ? l.sonosSelected : null,
          action: () async {
            if (await _confirm(l.sonosSelectPrompt(room.name))) {
              await controller.selectRoom(room);
            }
          },
        ),
      if (state.selected != null) ...[
        (
          title: l.sonosVolumeDown,
          value: '${(state.volume * 100).round()}%',
          action: () => controller.setVolume(state.volume - 0.05),
        ),
        (
          title: l.sonosVolumeUp,
          value: null,
          action: () => controller.setVolume(state.volume + 0.05),
        ),
        for (final room in state.rooms.where(
          (room) => room.visible && room.id != state.selectedId,
        ))
          if (room.coordinatorId == state.selected!.coordinatorId)
            (
              title: l.sonosRemoveRoom(room.name),
              value: null,
              action: () async {
                if (await _confirm(l.sonosUngroupPrompt(room.name))) {
                  await controller.ungroup(room);
                }
              },
            )
          else
            (
              title: l.sonosGroupRoom(room.name),
              value: null,
              action: () async {
                if (await _confirm(
                  l.sonosGroupPrompt(room.name, state.selected!.name),
                )) {
                  await controller.group(room);
                }
              },
            ),
        if (state.rooms
                .where(
                  (room) =>
                      room.visible &&
                      room.coordinatorId == state.selected!.coordinatorId,
                )
                .length >
            1)
          (
            title: l.sonosUngroupSelected,
            value: null,
            action: () async {
              if (await _confirm(l.sonosUngroupPrompt(state.selected!.name))) {
                await controller.ungroup(state.selected!);
              }
            },
          ),
      ],
      (
        title: l.sonosHelp,
        value: null,
        action: () async {
          await showCupertinoDialog<void>(
            context: context,
            builder: (context) => CupertinoAlertDialog(
              title: Text(l.sonosTitle),
              content: Text(l.sonosHelpText),
              actions: [
                CupertinoDialogAction(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l.sonosContinue),
                ),
              ],
            ),
          );
        },
      ),
    ];
    if (selectedDisplayItem >= _rows.length) selectedDisplayItem = 0;
    return CupertinoPageScaffold(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(4),
            child: Text(
              state.scanning
                  ? l.sonosSearching
                  : state.error != null
                  ? sonosError(context, state.error!)
                  : state.selected?.name ?? l.sonosThisPhone,
              style: IpodTypography.caption.copyWith(
                color: context.appPrimaryTextColor,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (state.busy || state.scanning) const CupertinoActivityIndicator(),
          Expanded(
            child: CupertinoScrollbar(
              controller: scrollController,
              child: ListView.builder(
                controller: scrollController,
                itemExtent: displayTileHeight,
                itemCount: _rows.length,
                itemBuilder: (context, index) => SettingsListTile(
                  text: _rows[index].title,
                  value: _rows[index].value,
                  isSelected: selectedDisplayItem == index,
                  onTap: () => _select(index),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
