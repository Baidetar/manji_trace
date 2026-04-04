import 'package:flutter/material.dart';
import 'package:manji_trace/models/enum/play_status.dart';
import 'package:manji_trace/pages/local_search/controllers/local_search_controller.dart';
import 'package:manji_trace/pages/local_search/models/local_select_filter.dart';
import 'package:get/get.dart';

class SelectPlayStatusView extends StatefulWidget {
  const SelectPlayStatusView({required this.localSearchController, super.key});
  final LocalSearchController localSearchController;

  @override
  State<SelectPlayStatusView> createState() => _SelectPlayStatusViewState();
}

class _SelectPlayStatusViewState extends State<SelectPlayStatusView> {
  LocalSelectFilter get localSelectFilter =>
      widget.localSearchController.localSelectFilter;

  @override
  Widget build(BuildContext context) {
    return GetBuilder(
      init: widget.localSearchController,
      tag: widget.localSearchController.tag,
      builder: (_) => Scaffold(
        body: ListView.builder(
          itemCount: PlayStatus.values.length,
          itemBuilder: (context, index) {
            final playStatus = PlayStatus.values[index];
            return RadioListTile<PlayStatus>( // ignore: deprecated_member_use
                title: Text(playStatus.text),
                toggleable: true,
                value: playStatus,
                groupValue: localSelectFilter.playStatus,
                onChanged: (value) {
                  widget.localSearchController.setPlayStatus(value);
                });
          },
        ),
      ),
    );
  }
}
