package net.stafforini.agentremote;

import android.app.Activity;
import android.graphics.Insets;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.window.OnBackInvokedCallback;
import android.window.OnBackInvokedDispatcher;

/**
 * Shows the single page at {@link BuildConfig#BASE_URL} and nothing else.
 *
 * <p>Navigation to any other origin is silently dropped, never handed to
 * another app, so the WebView cannot be used as a general browser.
 */
public class MainActivity extends Activity {
  private static final Uri BASE = Uri.parse(BuildConfig.BASE_URL);

  /**
   * How long an explicit load may take before it counts as failed.  An
   * unreachable Tailscale peer drops packets rather than refusing them,
   * so without this the WebView waits minutes for TCP to give up.
   */
  private static final long LOAD_TIMEOUT_MS = 15_000;

  private WebView web;
  private View errorView;
  private View loadingView;
  private final Handler handler = new Handler(Looper.getMainLooper());
  private final Runnable loadTimeout = this::onLoadTimeout;
  private String failedUrl;
  private boolean backCallbackRegistered;
  private final OnBackInvokedCallback goBack = () -> web.goBack();

  @Override
  protected void onCreate(Bundle state) {
    super.onCreate(state);

    FrameLayout root = new FrameLayout(this);
    // Edge-to-edge is enforced from API 35, which makes adjustResize a
    // no-op; pad for the system bars and the IME ourselves instead.
    root.setOnApplyWindowInsetsListener((v, insets) -> {
      Insets i = insets.getInsets(WindowInsets.Type.systemBars()
          | WindowInsets.Type.displayCutout() | WindowInsets.Type.ime());
      v.setPadding(i.left, i.top, i.right, i.bottom);
      return WindowInsets.CONSUMED;
    });

    web = new WebView(this);
    WebSettings s = web.getSettings();
    s.setJavaScriptEnabled(true);
    s.setDomStorageEnabled(true);
    s.setAllowFileAccess(false);
    s.setAllowContentAccess(false);
    s.setSupportMultipleWindows(false);
    s.setJavaScriptCanOpenWindowsAutomatically(false);
    s.setGeolocationEnabled(false);
    s.setSupportZoom(false);
    web.setDownloadListener((url, ua, disposition, mime, length) -> { });
    web.setWebViewClient(new Client());
    root.addView(web);

    errorView = buildErrorView();
    errorView.setVisibility(View.GONE);
    root.addView(errorView);

    loadingView = buildLoadingView();
    loadingView.setVisibility(View.GONE);
    root.addView(loadingView);

    setContentView(root);

    // A restored WebView reloads its page itself; it still needs the
    // connecting screen and timeout, or an unreachable host leaves it black.
    if (state != null && web.restoreState(state) != null) {
      showLoading();
    } else {
      load(BuildConfig.BASE_URL);
    }
  }

  private View buildLoadingView() {
    LinearLayout box = new LinearLayout(this);
    box.setOrientation(LinearLayout.VERTICAL);
    box.setGravity(Gravity.CENTER);
    box.addView(new ProgressBar(this));
    TextView msg = new TextView(this);
    msg.setGravity(Gravity.CENTER);
    msg.setTextSize(18);
    msg.setText("Connecting to " + BuildConfig.BASE_URL);
    box.addView(msg);
    return box;
  }

  /** Load URL behind the connecting screen, failing after a timeout. */
  private void load(String url) {
    showLoading();
    web.loadUrl(url);
  }

  /** Show the connecting screen until a page commits or the timeout fires. */
  private void showLoading() {
    failedUrl = null;
    errorView.setVisibility(View.GONE);
    web.setVisibility(View.INVISIBLE);
    loadingView.setVisibility(View.VISIBLE);
    handler.removeCallbacks(loadTimeout);
    handler.postDelayed(loadTimeout, LOAD_TIMEOUT_MS);
  }

  private void showPage() {
    handler.removeCallbacks(loadTimeout);
    loadingView.setVisibility(View.GONE);
    errorView.setVisibility(View.GONE);
    web.setVisibility(View.VISIBLE);
  }

  private void showError(String url) {
    handler.removeCallbacks(loadTimeout);
    failedUrl = url;
    loadingView.setVisibility(View.GONE);
    web.setVisibility(View.INVISIBLE);
    errorView.setVisibility(View.VISIBLE);
  }

  private void onLoadTimeout() {
    String url = web.getUrl();
    showError(url != null && sameOrigin(Uri.parse(url))
        ? url : BuildConfig.BASE_URL);
    web.stopLoading();
  }

  private View buildErrorView() {
    LinearLayout box = new LinearLayout(this);
    box.setOrientation(LinearLayout.VERTICAL);
    box.setGravity(Gravity.CENTER);
    int pad = (int) (24 * getResources().getDisplayMetrics().density);
    box.setPadding(pad, pad, pad, pad);

    TextView msg = new TextView(this);
    msg.setGravity(Gravity.CENTER);
    msg.setTextSize(18);
    msg.setText("Cannot reach " + BuildConfig.BASE_URL
        + "\n\nIs the Mac awake, on Tailscale, and serving the page?");
    box.addView(msg);

    Button retry = new Button(this);
    retry.setText("Retry");
    retry.setOnClickListener(v -> retry());
    LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT,
        LinearLayout.LayoutParams.WRAP_CONTENT);
    lp.topMargin = pad;
    box.addView(retry, lp);
    return box;
  }

  private void retry() {
    load(failedUrl != null ? failedUrl : BuildConfig.BASE_URL);
  }

  @Override
  protected void onResume() {
    super.onResume();
    web.onResume();
    if (failedUrl != null) {
      retry();
    }
  }

  @Override
  protected void onPause() {
    web.onPause();
    super.onPause();
  }

  @Override
  protected void onSaveInstanceState(Bundle out) {
    super.onSaveInstanceState(out);
    web.saveState(out);
  }

  @Override
  protected void onDestroy() {
    handler.removeCallbacks(loadTimeout);
    web.destroy();
    super.onDestroy();
  }

  /** Intercept Back only while the WebView has history to go back to. */
  private void updateBackCallback() {
    boolean want = web.canGoBack();
    if (want == backCallbackRegistered) {
      return;
    }
    OnBackInvokedDispatcher d = getOnBackInvokedDispatcher();
    if (want) {
      d.registerOnBackInvokedCallback(
          OnBackInvokedDispatcher.PRIORITY_DEFAULT, goBack);
    } else {
      d.unregisterOnBackInvokedCallback(goBack);
    }
    backCallbackRegistered = want;
  }

  private static int effectivePort(Uri u) {
    if (u.getPort() != -1) {
      return u.getPort();
    }
    return "https".equals(u.getScheme()) ? 443 : 80;
  }

  static boolean sameOrigin(Uri u) {
    return BASE.getScheme().equalsIgnoreCase(String.valueOf(u.getScheme()))
        && BASE.getHost().equalsIgnoreCase(String.valueOf(u.getHost()))
        && effectivePort(BASE) == effectivePort(u);
  }

  private class Client extends WebViewClient {
    @Override
    public boolean shouldOverrideUrlLoading(WebView view,
                                            WebResourceRequest req) {
      // Returning true cancels the navigation; nothing else is launched.
      return !sameOrigin(req.getUrl());
    }

    @Override
    public void onReceivedError(WebView view, WebResourceRequest req,
                                WebResourceError err) {
      if (req.isForMainFrame()) {
        showError(req.getUrl().toString());
      }
    }

    @Override
    public void onPageCommitVisible(WebView view, String url) {
      // Called for the page that replaced an error or connecting
      // screen; a timed-out load was stopped and never commits.
      if (failedUrl == null) {
        showPage();
      }
    }

    @Override
    public void doUpdateVisitedHistory(WebView view, String url,
                                       boolean isReload) {
      updateBackCallback();
    }

    @Override
    public boolean onRenderProcessGone(WebView view,
                                       RenderProcessGoneDetail detail) {
      // The WebView is unusable once its renderer dies; start afresh
      // rather than letting the default handler kill the app.
      recreate();
      return true;
    }
  }
}
