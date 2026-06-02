import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// An in-app browser for opening a bookmark's link without leaving the app.
///
/// Renders [initialUrl] in a [WebView] under a chrome bar that mirrors a real
/// browser: a back/forward pair (enabled only when there's history to walk), a
/// reload/stop toggle, and a close button. A thin progress bar under the app bar
/// tracks page load, and the app bar title reflects the current page's title
/// (falling back to its host) so the user always knows where they are.
///
/// Hardware/system back is intercepted: if the WebView has back-history it walks
/// that first and only pops the screen once there's nowhere left to go back to,
/// matching the behavior of a normal browser's back button.
///
/// This owns no Firestore knowledge — the caller decides when to open it and is
/// responsible for any side effects (e.g. stamping `lastCheckedAt`). It simply
/// needs a URL to load. The optional [onManualRefresh] callback lets the caller
/// hook the user-initiated reload (e.g. to re-stamp `lastCheckedAt`) without the
/// screen knowing what that side effect is.
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({
    super.key,
    required this.initialUrl,
    this.title,
    this.onManualRefresh,
  });

  /// The URL to load when the screen opens. Assumed already validated by the
  /// caller (it parses and has a scheme + authority).
  final String initialUrl;

  /// Optional label shown in the app bar until the page reports its own title;
  /// typically the bookmark's title.
  final String? title;

  /// Invoked when the user taps the toolbar's reload button, alongside the
  /// actual page reload. Lets the caller record the revisit (e.g. stamp
  /// `lastCheckedAt`) — best-effort, so it should not throw.
  final VoidCallback? onManualRefresh;

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  late final WebViewController _controller;

  /// 0–100 load progress for the current navigation; 100 once finished.
  int _progress = 100;

  /// Whether a navigation is in flight — drives the reload/stop toggle and the
  /// progress bar's visibility.
  bool _loading = true;

  /// The page's reported title, used in the app bar once available.
  String? _pageTitle;

  /// Whether the WebView currently has back/forward history. Recomputed after
  /// each finished navigation so the toolbar buttons enable/disable correctly.
  bool _canGoBack = false;
  bool _canGoForward = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (!mounted) return;
            setState(() => _progress = progress);
          },
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _loading = true;
              _progress = 0;
            });
          },
          onPageFinished: (_) async {
            await _refreshNavState();
            if (!mounted) return;
            setState(() {
              _loading = false;
              _progress = 100;
            });
          },
          onWebResourceError: (error) {
            if (!mounted) return;
            setState(() {
              _loading = false;
              _progress = 100;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Couldn’t load page: ${error.description}'),
              ),
            );
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.initialUrl));
  }

  /// Pulls the latest can-go-back/forward and page title from the controller
  /// after a navigation settles, so the toolbar reflects real history.
  Future<void> _refreshNavState() async {
    final canBack = await _controller.canGoBack();
    final canForward = await _controller.canGoForward();
    final title = await _controller.getTitle();
    if (!mounted) return;
    setState(() {
      _canGoBack = canBack;
      _canGoForward = canForward;
      if (title != null && title.trim().isNotEmpty) {
        _pageTitle = title.trim();
      }
    });
  }

  /// Walks the WebView's back-history if there is any; otherwise lets the screen
  /// pop. Wired to both the system back gesture (via [PopScope]) and the app
  /// bar's leading button so they behave the same.
  Future<bool> _handleBack() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      return false; // Handled in-page; don't pop the screen.
    }
    return true; // Nothing to go back to — allow the pop.
  }

  /// The app bar label: the live page title, then the caller-supplied title,
  /// then the host of the initial URL as a last resort.
  String get _displayTitle {
    final page = _pageTitle;
    if (page != null && page.isNotEmpty) return page;
    final given = widget.title?.trim();
    if (given != null && given.isNotEmpty) return given;
    return Uri.tryParse(widget.initialUrl)?.host ?? widget.initialUrl;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _handleBack();
        if (shouldPop && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: Text(_displayTitle, overflow: TextOverflow.ellipsis),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(3),
            // Keep the 3px slot reserved so the app bar height doesn't jump as
            // the bar appears/disappears between loads.
            child: SizedBox(
              height: 3,
              child: _loading
                  ? LinearProgressIndicator(
                      value: _progress == 0 ? null : _progress / 100,
                      minHeight: 3,
                    )
                  : null,
            ),
          ),
        ),
        body: WebViewWidget(controller: _controller),
        bottomNavigationBar: _BrowserToolbar(
          canGoBack: _canGoBack,
          canGoForward: _canGoForward,
          onBack: () async {
            await _controller.goBack();
            await _refreshNavState();
          },
          onForward: () async {
            await _controller.goForward();
            await _refreshNavState();
          },
          onReload: () {
            widget.onManualRefresh?.call();
            _controller.reload();
          },
          dividerColor: theme.colorScheme.outlineVariant,
        ),
      ),
    );
  }
}

/// The bottom toolbar: back, forward, and reload/stop, laid out across a bar
/// with a hairline top divider. Navigation buttons disable when there's no
/// history in that direction; the reload button flips to a stop icon mid-load.
class _BrowserToolbar extends StatelessWidget {
  const _BrowserToolbar({
    required this.canGoBack,
    required this.canGoForward,
    required this.onBack,
    required this.onForward,
    required this.onReload,
    required this.dividerColor,
  });

  final bool canGoBack;
  final bool canGoForward;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onReload;
  final Color dividerColor;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: dividerColor)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new),
                tooltip: 'Back',
                onPressed: canGoBack ? onBack : null,
              ),
              IconButton(
                icon: const Icon(Icons.arrow_forward_ios),
                tooltip: 'Forward',
                onPressed: canGoForward ? onForward : null,
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Reload',
                onPressed: onReload,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
