import 'package:flutter/material.dart';
import 'package:manji_trace/dao/anime_dao.dart';
import 'package:manji_trace/models/enum/play_status.dart';
import 'package:manji_trace/pages/anime_detail/controllers/anime_controller.dart';

showDialogSelectPlayStatus(
    BuildContext context, AnimeController animeController) {
  // Use a stateful widget or a GetX controller for managing the selected value
  // For simplicity here, we'll use a local variable and update the controller when confirmed.
  PlayStatus? _selectedStatus = animeController.anime.getPlayStatus();

  showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder( // Use StatefulBuilder to manage local state within the dialog
          builder: (BuildContext dialogContext, StateSetter setState) {
            return AlertDialog( // Use AlertDialog for better dialog structure
              title: const Text("播放状态"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: PlayStatus.values.map((status) {
                  return RadioListTile<PlayStatus>(
                    title: Text(status.text),
                    value: status,
                    groupValue: _selectedStatus,
                    onChanged: (PlayStatus? value) {
                      if (value != null) {
                        setState(() { // Update local state
                          _selectedStatus = value;
                        });
                        // The actual update to controller/DAO will happen on confirmation
                      }
                    },
                  );
                }).toList(),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text("取消"),
                ),
                TextButton(
                  onPressed: () {
                    if (_selectedStatus != null) {
                      animeController.anime.playStatus = _selectedStatus!.text;
                      animeController.updateAnimeInfo();
                      AnimeDao.updateAnimePlayStatusByAnimeId(
                          animeController.anime.animeId, _selectedStatus!.text);
                      Navigator.pop(dialogContext);
                    }
                  },
                  child: const Text("确定"),
                ),
              ],
            );
          },
        );
      });
}

Future<PlayStatus?> showPlayStatusPicker(
    {required BuildContext context, PlayStatus? playStatus}) async {
  return showDialog(
    context: context,
    builder: (context) {
      // Using RadioGroup from flutter_hooks or a custom implementation might be cleaner
      // For now, we'll stick to a simpler approach if RadioGroup is not directly available
      // as a standalone widget. Let's assume a standard way to handle RadioGroup logic.
      // If RadioGroup is a wrapper, we might need to adapt.
      // For now, using a SimpleDialog with RadioListTile and managing state.
      PlayStatus? selectedStatus = playStatus;

      return SimpleDialog(
        title: const Text("播放状态"),
        children: PlayStatus.values.map((status) {
          return RadioListTile<PlayStatus>(
            title: Text(status.text),
            value: status,
            groupValue: selectedStatus,
            onChanged: (PlayStatus? value) {
              if (value != null) {
                selectedStatus = value; // Update local selection
                Navigator.pop(context, value); // Return the selected value
              }
            },
          );
        }).toList(),
      );
    },
  );
}
