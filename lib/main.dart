import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');

  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }

  // 풀스크린(상단/하단 바 자동 숨김)
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    ),
  );

  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Attendance (WebView)',
      home: WebShell(),
    ),
  );
}

class WebShell extends StatefulWidget {
  const WebShell({super.key});
  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> {
  final GlobalKey webViewKey = GlobalKey();
  InAppWebViewController? _controller;
  PullToRefreshController? _pullToRefreshController;

  String _url = dotenv.env['WEB_APP_URL']?.trim() ?? '';
  double _progress = 0;

  // UX 튜닝 상태값들
  StreamSubscription? _connSub;
  bool _offline = false;
  bool _hadFirstLoad = false;
  String? _errorMessage;
  DateTime? _lastBackPress;

  @override
  void initState() {
    super.initState();

    _pullToRefreshController = PullToRefreshController(
      onRefresh: () async {
        if (Platform.isAndroid) {
          await _controller?.reload();
        } else if (Platform.isIOS) {
          final url = await _controller?.getUrl();
          if (url != null) {
            await _controller?.loadUrl(urlRequest: URLRequest(url: url));
          }
        }
      },
    );

    // 초기 상태 1회 확인 (이미 있으니 유지)
    Connectivity().checkConnectivity().then((res) {
      final off = (res is List<ConnectivityResult>)
          ? res.every((e) => e == ConnectivityResult.none)
          : (res == ConnectivityResult.none);
      _offline = off;
      if (mounted) setState(() {});
    });

    // ✅ 실시간 변경 구독 추가
    _connSub = Connectivity().onConnectivityChanged.listen((event) {
      bool off;
      if (event is List<ConnectivityResult>) {
        off = event.every((e) => e == ConnectivityResult.none);
      } else if (event is ConnectivityResult) {
        off = event == ConnectivityResult.none;
      } else {
        off = false;
      }
      if (mounted) setState(() => _offline = off);
    });
  }

  @override
  void dispose() {
    _connSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final initialUrl = _url.isEmpty ? WebUri('about:blank') : WebUri(_url);

    return WillPopScope(
      onWillPop: () async {
        // WebView 뒤로가기 먼저 처리
        if (_controller != null && await _controller!.canGoBack()) {
          _controller!.goBack();
          return false;
        }
        // Android: 두 번 눌러 종료
        if (Platform.isAndroid) {
          final now = DateTime.now();
          if (_lastBackPress == null ||
              now.difference(_lastBackPress!) > const Duration(seconds: 2)) {
            _lastBackPress = now;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('한 번 더 누르면 종료됩니다')));
            return false;
          }
        }
        return true;
      },
      child: Scaffold(
        body: Stack(
          children: [
            InAppWebView(
              key: webViewKey,
              initialUrlRequest: URLRequest(url: initialUrl),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                javaScriptCanOpenWindowsAutomatically: true,
                mediaPlaybackRequiresUserGesture: false,
                allowsInlineMediaPlayback: true,
                useOnDownloadStart: true,
                useShouldOverrideUrlLoading: true,
                transparentBackground: false,
                allowsBackForwardNavigationGestures: true,
              ),
              pullToRefreshController: _pullToRefreshController,
              onWebViewCreated: (controller) async {
                _controller = controller;
              },
              // 웹에서 카메라/마이크 권한 요청 시 자동 허용(안드로이드)
              onPermissionRequest: (controller, request) async {
                return PermissionResponse(
                  resources: request.resources,
                  action: PermissionResponseAction.GRANT,
                );
              },
              // 웹 geolocation 허용
              onGeolocationPermissionsShowPrompt: (controller, origin) async {
                return GeolocationPermissionShowPromptResponse(
                  origin: origin,
                  allow: true,
                  retain: true,
                );
              },
              // window.open/new tab → 같은 WebView에서 열기
              onCreateWindow: (controller, createWindowAction) async {
                final targetUrl = createWindowAction.request.url;
                if (targetUrl != null) {
                  _controller?.loadUrl(urlRequest: URLRequest(url: targetUrl));
                  return true; // 우리가 처리함
                }
                return false;
              },
              onLoadStart: (controller, url) async {
                setState(() {
                  _errorMessage = null;
                });
              },
              onLoadStop: (controller, url) async {
                _pullToRefreshController?.endRefreshing();
                setState(() => _hadFirstLoad = true);
              },
              onLoadError: (controller, url, code, message) {
                _pullToRefreshController?.endRefreshing();
                setState(() => _errorMessage = message);
              },
              onProgressChanged: (controller, progress) {
                setState(() => _progress = progress / 100.0);
                if (progress == 100) {
                  _pullToRefreshController?.endRefreshing();
                }
              },
              onConsoleMessage: (controller, consoleMessage) {
                // 디버깅 시 활성화
                // debugPrint('[WEB] ${consoleMessage.message}');
              },
              shouldOverrideUrlLoading: (controller, navAction) async {
                final uri = navAction.request.url;
                if (uri == null) return NavigationActionPolicy.ALLOW;

                // 일반 웹 스킴은 내부에서 열기
                const allowSchemes = {
                  'http',
                  'https',
                  'file',
                  'about',
                  'data',
                  'javascript',
                };
                if (allowSchemes.contains(uri.scheme)) {
                  return NavigationActionPolicy.ALLOW;
                }

                // tel:, mailto:, intent:, kakaolink: 등은 외부 앱으로
                final parsed = Uri.parse(uri.toString());
                if (await canLaunchUrl(parsed)) {
                  await launchUrl(parsed, mode: LaunchMode.externalApplication);
                  return NavigationActionPolicy.CANCEL;
                }
                return NavigationActionPolicy.ALLOW;
              },
              onDownloadStartRequest: (controller, request) async {
                final url = request.url.toString();
                final parsed = Uri.parse(url);
                if (await canLaunchUrl(parsed)) {
                  await launchUrl(parsed, mode: LaunchMode.externalApplication);
                }
              },
            ),

            // 오프라인 배너
            if (_offline)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.red,
                  padding: const EdgeInsets.symmetric(
                    vertical: 10,
                    horizontal: 16,
                  ),
                  child: const SafeArea(
                    bottom: false,
                    child: Text(
                      '오프라인 상태입니다',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),

            // 첫 로딩 인디케이터
            if (!_hadFirstLoad)
              AnimatedOpacity(
                opacity: _progress < 1.0 ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: const Center(child: CircularProgressIndicator()),
              ),

            // 에러 오버레이
            if (_errorMessage != null)
              Positioned.fill(
                child: Container(
                  color: Colors.white,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.wifi_off, size: 48),
                        const SizedBox(height: 12),
                        Text(
                          '페이지를 불러오지 못했습니다.\n$_errorMessage',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          onPressed: () {
                            setState(() => _errorMessage = null);
                            _controller?.reload();
                          },
                          child: const Text('다시 시도'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
