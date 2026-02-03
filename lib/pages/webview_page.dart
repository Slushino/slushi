import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class WebViewPage extends StatefulWidget {
  final String title;
  final String url;

  const WebViewPage({super.key, required this.title, required this.url});

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) async {
            final url = request.url;
            final lower = url.toLowerCase();

            // Debug
            print('NAV REQUEST: $url');

            if (lower.startsWith('mailto:') || lower.startsWith('tel:')) {
              final uri = Uri.parse(url);
              await launchUrl(uri, mode: LaunchMode.externalApplication);
              return NavigationDecision.prevent;
            }

            final uri = Uri.parse(url);
            if (uri.scheme != 'http' && uri.scheme != 'https') {
              print('BLOCKING unknown scheme: ${uri.scheme} ($url)');
              return NavigationDecision.prevent;
            }

            return NavigationDecision.navigate;
          },
          onUrlChange: (change) async {
            final url = change.url ?? '';
            if (url.isEmpty) return;

            final lower = url.toLowerCase();
            print('URL CHANGE: $url');

            if (lower.startsWith('mailto:') || lower.startsWith('tel:')) {
              final uri = Uri.parse(url);
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
          onWebResourceError: (error) {
            print('WEBVIEW ERROR: ${error.errorCode} ${error.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 👇 Dette er AppBar (topplinja). Den beviser at riktig side åpnes.
      appBar: AppBar(title: Text(widget.title)),
      body: WebViewWidget(controller: _controller),
    );
  }
}
