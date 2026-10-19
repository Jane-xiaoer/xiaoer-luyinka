// 整理用的大模型：默认走小耳云端的中转（不留记录）；用户在设置里填了自己的 key，就从这台设备直接调他的模型，
// key 和内容都不经过小耳的服务器。都是 OpenAI 兼容的 /chat/completions。
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'cloud.dart';

class Provider {
  final String name, base, model;
  const Provider(this.name, this.base, this.model);
}

/// 常用的几家（模型名可以在设置里改）。
const providers = [
  Provider('DeepSeek', 'https://api.deepseek.com/v1', 'deepseek-chat'),
  Provider('通义千问', 'https://dashscope.aliyuncs.com/compatible-mode/v1', 'qwen-plus'),
  Provider('Kimi', 'https://api.moonshot.cn/v1', 'moonshot-v1-32k'),
  Provider('智谱', 'https://open.bigmodel.cn/api/paas/v4', 'glm-4-flash'),
  Provider('OpenAI', 'https://api.openai.com/v1', 'gpt-4o-mini'),
  Provider('自定义', '', ''),
];

class Llm {
  final Cloud cloud;
  final Map<String, dynamic> Function() settings; // store.settings['llm']：{own, base, key, model}
  static Llm? instance; // App 里只有一个（问答、单段重新整理用）
  Llm(this.cloud, this.settings) {
    instance = this;
  }

  bool get own {
    final s = settings();
    return s['own'] == true && (s['base'] ?? '').toString().isNotEmpty && (s['key'] ?? '').toString().isNotEmpty;
  }

  String get label => own ? '自己的模型 · ${settings()['model']}' : '小耳提供';

  Future<String> chat(String system, String user, {double temperature = 0.2}) async {
    final messages = [
      {'role': 'system', 'content': system},
      {'role': 'user', 'content': user},
    ];
    final out = own ? await _direct(messages, temperature) : await _relay(messages, temperature);
    return out.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
  }

  Future<String> _direct(List<Map<String, String>> messages, double temperature) async {
    final s = settings();
    final r = await http
        .post(Uri.parse('${s['base'].toString().replaceAll(RegExp(r'/+$'), '')}/chat/completions'),
            headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer ${s['key']}'},
            body: jsonEncode({'model': s['model'], 'temperature': temperature, 'messages': messages}))
        .timeout(const Duration(minutes: 5));
    final body = utf8.decode(r.bodyBytes);
    if (r.statusCode != 200) {
      throw CloudError('你的模型没回好（${r.statusCode}）：${body.length > 200 ? body.substring(0, 200) : body}', r.statusCode);
    }
    return (jsonDecode(body)['choices'][0]['message']['content'] ?? '').toString();
  }

  Future<String> _relay(List<Map<String, String>> messages, double temperature) async {
    Future<http.Response> post() => http
        .post(Uri.parse('${cloud.base}/v1/llm'),
            headers: {'Authorization': 'Bearer ${cloud.token ?? ''}', 'Content-Type': 'application/json'},
            body: jsonEncode({'messages': messages, 'temperature': temperature}))
        .timeout(const Duration(minutes: 5));
    if (cloud.token == null) await cloud.register();
    var r = await post();
    if (r.statusCode == 401) {
      await cloud.register();
      r = await post();
    }
    final body = utf8.decode(r.bodyBytes);
    final d = body.isEmpty ? <String, dynamic>{} : jsonDecode(body) as Map<String, dynamic>;
    if (r.statusCode != 200) throw CloudError(d['error']?.toString() ?? '整理出错（${r.statusCode}）', r.statusCode);
    return d['content'] as String;
  }
}
