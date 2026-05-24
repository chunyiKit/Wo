import 'package:flutter/material.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SafeArea(
        top: false,
        child: ListView(
          children: const [
            ListTile(title: Text('账号与安全'), trailing: Icon(Icons.chevron_right)),
            ListTile(title: Text('通知偏好'), trailing: Icon(Icons.chevron_right)),
            ListTile(
              title: Text('外观 · 深色模式'),
              trailing: Icon(Icons.chevron_right),
            ),
            ListTile(title: Text('语言'), trailing: Icon(Icons.chevron_right)),
            ListTile(title: Text('清除缓存'), trailing: Icon(Icons.chevron_right)),
          ],
        ),
      ),
    );
  }
}
