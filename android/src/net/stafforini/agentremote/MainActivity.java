package net.stafforini.agentremote;

import android.app.Activity;
import android.content.SharedPreferences;
import android.graphics.Insets;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.window.OnBackInvokedCallback;
import android.window.OnBackInvokedDispatcher;

/**
 * Shows the single page at the server address the user entered, and
 * nothing else.
 *
 * <p>The address is asked for on first launch, pre-filled with
 * {@link BuildConfig#BASE_URL} when the build named one, and must be a
 * Tailscale address, since the page is served over plain HTTP that only
 * the tailnet encrypts.  Navigation to any other origin is silently
 * dropped, never handed to another app, so the WebView cannot be used
 * as a general browser.
 */
public class MainActivity extends Activity {
  private static final String PREFS = "agent-remote";
  private static final String KEY_URL = "url";
  private static final int DEFAULT_PORT = 8787;

  /** The page's address, or null until the user has entered one. */
  private Uri base;

  /**
   * How long an explicit load may take before it counts as failed.  An
   * unreachable Tailscale peer drops packets rather than refusing them,
   * so without this the WebView waits minutes for TCP to give up.
   */
  private static final long LOAD_TIMEOUT_MS = 15_000;

  private WebView web;
  private View errorView;
  private TextView errorMessage;
  private View loadingView;
  private TextView loadingMessage;
  private View setupView;
  private EditText setupInput;
  private TextView setupError;
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

    setupView = buildSetupView();
    setupView.setVisibility(View.GONE);
    root.addView(setupView);

    setContentView(root);

    String saved = prefs().getString(KEY_URL, null);
    if (saved == null) {
      showSetup();
      return;
    }
    setBase(Uri.parse(saved));
    // A restored WebView reloads its page itself; it still needs the
    // connecting screen and timeout, or an unreachable host leaves it black.
    if (state != null && web.restoreState(state) != null) {
      showLoading();
    } else {
      load(base.toString());
    }
  }

  private SharedPreferences prefs() {
    return getSharedPreferences(PREFS, MODE_PRIVATE);
  }

  private void setBase(Uri uri) {
    base = uri;
    loadingMessage.setText("Connecting to " + uri);
    errorMessage.setText("Cannot reach " + uri
        + "\n\nIs the computer awake, on Tailscale, and serving the page?");
  }

  private View buildSetupView() {
    LinearLayout box = new LinearLayout(this);
    box.setOrientation(LinearLayout.VERTICAL);
    box.setGravity(Gravity.CENTER);
    int pad = (int) (24 * getResources().getDisplayMetrics().density);
    box.setPadding(pad, pad, pad, pad);

    TextView msg = new TextView(this);
    msg.setGravity(Gravity.CENTER);
    msg.setTextSize(18);
    msg.setText("Server address\n\nThe Tailscale address of the computer "
        + "running agent-remote-mode, such as 100.101.102.103:8787.");
    box.addView(msg);

    setupInput = new EditText(this);
    setupInput.setSingleLine(true);
    setupInput.setHint("100.x.y.z:" + DEFAULT_PORT);
    setupInput.setInputType(android.text.InputType.TYPE_CLASS_TEXT
        | android.text.InputType.TYPE_TEXT_VARIATION_URI);
    setupInput.setImeOptions(EditorInfo.IME_ACTION_GO);
    setupInput.setOnEditorActionListener((v, action, event) -> {
      saveSetup();
      return true;
    });
    LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT,
        LinearLayout.LayoutParams.WRAP_CONTENT);
    lp.topMargin = pad;
    box.addView(setupInput, lp);

    setupError = new TextView(this);
    setupError.setGravity(Gravity.CENTER);
    setupError.setTextColor(0xFFFF6B6B);
    box.addView(setupError);

    Button connect = new Button(this);
    connect.setText("Connect");
    connect.setOnClickListener(v -> saveSetup());
    LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT,
        LinearLayout.LayoutParams.WRAP_CONTENT);
    blp.topMargin = pad;
    box.addView(connect, blp);
    return box;
  }

  private void showSetup() {
    handler.removeCallbacks(loadTimeout);
    failedUrl = null;
    web.stopLoading();
    web.setVisibility(View.INVISIBLE);
    loadingView.setVisibility(View.GONE);
    errorView.setVisibility(View.GONE);
    setupError.setText("");
    setupInput.setText(base != null ? base.toString() : BuildConfig.BASE_URL);
    setupView.setVisibility(View.VISIBLE);
  }

  private void saveSetup() {
    Uri uri;
    try {
      uri = parseAddress(setupInput.getText().toString());
    } catch (IllegalArgumentException e) {
      setupError.setText(e.getMessage());
      return;
    }
    prefs().edit().putString(KEY_URL, uri.toString()).apply();
    getSystemService(InputMethodManager.class)
        .hideSoftInputFromWindow(setupInput.getWindowToken(), 0);
    setBase(uri);
    setupView.setVisibility(View.GONE);
    web.clearHistory();
    load(uri.toString());
  }

  /**
   * Return the page address that TEXT names.  A missing scheme means
   * http, a missing port means {@link #DEFAULT_PORT}, and any path is
   * dropped.  Plain http is accepted only for a Tailscale address,
   * which the tailnet encrypts.
   *
   * @throws IllegalArgumentException with a message for the user
   */
  static Uri parseAddress(String text) {
    String t = text.trim();
    if (t.isEmpty()) {
      throw new IllegalArgumentException("Enter an address.");
    }
    if (!t.contains("://")) {
      t = "http://" + t;
    }
    Uri u = Uri.parse(t);
    String scheme = String.valueOf(u.getScheme()).toLowerCase();
    String host = u.getHost();
    if (!scheme.equals("http") && !scheme.equals("https")) {
      throw new IllegalArgumentException("Use an http:// or https:// address.");
    }
    if (host == null || host.isEmpty()) {
      throw new IllegalArgumentException("That address names no host.");
    }
    if (scheme.equals("http") && !isTailscaleHost(host)) {
      throw new IllegalArgumentException(
          "Plain http is allowed only to a Tailscale address "
          + "(100.64.0.0 to 100.127.255.255, or a .ts.net name).");
    }
    int port = u.getPort() != -1 ? u.getPort() : DEFAULT_PORT;
    return Uri.parse(scheme + "://" + host.toLowerCase() + ":" + port + "/");
  }

  /** Whether HOST is in Tailscale's 100.64.0.0/10 range or a .ts.net name. */
  static boolean isTailscaleHost(String host) {
    String h = host.toLowerCase();
    if (h.endsWith(".ts.net")) {
      return true;
    }
    String[] parts = h.split("\\.");
    if (parts.length != 4) {
      return false;
    }
    int[] octets = new int[4];
    for (int i = 0; i < 4; i++) {
      if (!parts[i].matches("[0-9]{1,3}")) {
        return false;
      }
      octets[i] = Integer.parseInt(parts[i]);
      if (octets[i] > 255) {
        return false;
      }
    }
    return octets[0] == 100 && (octets[1] & 0xC0) == 64;
  }

  private View buildLoadingView() {
    LinearLayout box = new LinearLayout(this);
    box.setOrientation(LinearLayout.VERTICAL);
    box.setGravity(Gravity.CENTER);
    box.addView(new ProgressBar(this));
    loadingMessage = new TextView(this);
    loadingMessage.setGravity(Gravity.CENTER);
    loadingMessage.setTextSize(18);
    box.addView(loadingMessage);
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
        ? url : base.toString());
    web.stopLoading();
  }

  private View buildErrorView() {
    LinearLayout box = new LinearLayout(this);
    box.setOrientation(LinearLayout.VERTICAL);
    box.setGravity(Gravity.CENTER);
    int pad = (int) (24 * getResources().getDisplayMetrics().density);
    box.setPadding(pad, pad, pad, pad);

    errorMessage = new TextView(this);
    errorMessage.setGravity(Gravity.CENTER);
    errorMessage.setTextSize(18);
    box.addView(errorMessage);

    Button retry = new Button(this);
    retry.setText("Retry");
    retry.setOnClickListener(v -> retry());
    LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT,
        LinearLayout.LayoutParams.WRAP_CONTENT);
    lp.topMargin = pad;
    box.addView(retry, lp);

    Button change = new Button(this);
    change.setText("Change address");
    change.setOnClickListener(v -> showSetup());
    box.addView(change, lp);
    return box;
  }

  private void retry() {
    load(failedUrl != null ? failedUrl : base.toString());
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

  private boolean sameOrigin(Uri u) {
    return base != null
        && base.getScheme().equalsIgnoreCase(String.valueOf(u.getScheme()))
        && base.getHost().equalsIgnoreCase(String.valueOf(u.getHost()))
        && effectivePort(base) == effectivePort(u);
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
