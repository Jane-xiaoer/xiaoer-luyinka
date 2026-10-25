// 左栏「录音豆」那一行右边的小圆点：连着是绿的，正在拉 / 处理是黄的，没连上不显示。
import 'package:flutter/material.dart';

import '../theme.dart';
import 'sync.dart';

class BeanDot extends StatelessWidget {
  final BeanSyncer bean;
  const BeanDot({super.key, required this.bean});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: bean,
    builder: (_, _) {
      final pulling = bean.store.recs.values.any(
        (r) => r.stage == 'pulling' && r.stem.startsWith('bean'),
      );
      if (!bean.connected && bean.here != true && !pulling)
        return const SizedBox();
      return Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: pulling && !bean.connected ? K.todo : K.live,
          shape: BoxShape.circle,
        ),
      );
    },
  );
}
