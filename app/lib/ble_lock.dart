// 蓝牙扫描一次只能一个人用：录音卡和录音豆各扫各的会互相把对方的扫描停掉（startScan / stopScan 是全局的）。
// 所有扫描都排进这一条队。
import 'dart:async';

Future<void> _tail = Future.value();

Future<T> bleLock<T>(Future<T> Function() task) {
  final prev = _tail;
  final done = Completer<void>();
  _tail = done.future;
  return prev.then((_) => task()).whenComplete(done.complete);
}
