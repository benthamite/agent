package net.stafforini.agentremote;

import android.app.Notification;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.net.Uri;
import android.os.IBinder;
import android.os.PowerManager;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Listens to Emacs for the notifications its sessions raise and shows
 * them, while the notification mode is not off.
 *
 * <p>It keeps one request to {@code /api/notifications} waiting at all
 * times: Emacs answers it when a notification arrives, or empty after 45
 * seconds, and the service asks again at once.  An answer arriving over
 * the network wakes a sleeping phone, so nothing needs to poll on a
 * timer, and a phone that was out of reach gets on its next request
 * every notification Emacs kept meanwhile.  Android requires a
 * foreground service to show a notification of its own while it runs.
 */
public class NotifyService extends Service {
  private static final int WATCHING_ID = 1;
  private static final int CONNECT_TIMEOUT_MS = 15_000;
  /** Longer than Emacs's 45-second wait, so its empty answer comes first. */
  private static final int READ_TIMEOUT_MS = 90_000;
  private static final long RETRY_MS = 15_000;

  private volatile boolean running;
  private Thread worker;
  private String status;
  private PowerManager.WakeLock wakeLock;

  @Override
  public void onCreate() {
    super.onCreate();
    Notifications.createChannels(this);
    wakeLock = getSystemService(PowerManager.class)
        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "agentremote:notify");
    wakeLock.setReferenceCounted(false);
    startForeground(WATCHING_ID, watching("Watching sessions"),
        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
  }

  @Override
  public int onStartCommand(Intent intent, int flags, int startId) {
    String url = Notifications.prefs(this).getString(Notifications.KEY_URL, null);
    if (Notifications.OFF.equals(Notifications.mode(this)) || url == null
        || !Notifications.permitted(this)) {
      stopSelf();
      return START_NOT_STICKY;
    }
    if (worker == null) {
      running = true;
      Uri base = Uri.parse(url);
      worker = new Thread(() -> listen(base), "agent-remote-notify");
      worker.start();
    }
    return START_STICKY;
  }

  @Override
  public void onDestroy() {
    running = false;
    if (worker != null) {
      worker.interrupt();
    }
    wakeLock.release();
    super.onDestroy();
  }

  @Override
  public IBinder onBind(Intent intent) {
    return null;
  }

  /** Ask BASE for notifications until the service stops. */
  private void listen(Uri base) {
    String epoch = null;
    long last = 0;
    while (running) {
      try {
        if (epoch == null) {
          // Start from now: what Emacs raised before is not news.
          JSONObject reply = fetch(base, "api/notifications");
          epoch = reply.getString("epoch");
          last = reply.getLong("last");
        } else {
          JSONObject reply = fetch(base, "api/notifications?epoch="
              + Uri.encode(epoch) + "&after=" + last + "&wait=1");
          if (!running) {
            return;
          }
          wakeLock.acquire(10_000);
          try {
            show(reply.getJSONArray("notifications"));
            epoch = reply.getString("epoch");
            last = reply.getLong("last");
          } finally {
            wakeLock.release();
          }
        }
        setStatus("Watching sessions");
      } catch (IOException | JSONException e) {
        if (!running) {
          return;
        }
        setStatus("Cannot reach " + base.getHost() + "; retrying");
        try {
          Thread.sleep(RETRY_MS);
        } catch (InterruptedException ie) {
          return;
        }
      }
    }
  }

  private static JSONObject fetch(Uri base, String path)
      throws IOException, JSONException {
    URL url = new URL(base.toString() + path);
    HttpURLConnection c = (HttpURLConnection) url.openConnection();
    c.setConnectTimeout(CONNECT_TIMEOUT_MS);
    c.setReadTimeout(READ_TIMEOUT_MS);
    c.setUseCaches(false);
    try {
      int code = c.getResponseCode();
      if (code != 200) {
        throw new IOException("HTTP " + code);
      }
      try (InputStream in = c.getInputStream()) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        for (int n; (n = in.read(buf)) != -1; ) {
          out.write(buf, 0, n);
        }
        return new JSONObject(out.toString(StandardCharsets.UTF_8.name()));
      }
    } finally {
      c.disconnect();
    }
  }

  private void show(JSONArray list) throws JSONException {
    String mode = Notifications.mode(this);
    if (Notifications.OFF.equals(mode)) {
      return;
    }
    String channel = Notifications.SOUND.equals(mode)
        ? Notifications.CHANNEL_SOUND : Notifications.CHANNEL_VISUAL;
    NotificationManager nm = getSystemService(NotificationManager.class);
    for (int i = 0; i < list.length(); i++) {
      JSONObject n = list.getJSONObject(i);
      String session = n.isNull("id") ? null : n.getString("id");
      if (session != null && Notifications.appVisible
          && session.equals(Notifications.viewing)) {
        continue;
      }
      Notification.Builder b = new Notification.Builder(this, channel)
          .setSmallIcon(R.drawable.ic_notification)
          .setContentTitle(n.optString("title"))
          .setContentText(n.optString("message"))
          .setWhen(n.optLong("time") * 1000)
          .setShowWhen(true)
          .setAutoCancel(true)
          .setCategory(Notification.CATEGORY_MESSAGE);
      b.setContentIntent(openIntent(session,
          n.isNull("name") ? null : n.getString("name")));
      nm.notify(Notifications.idFor(session), b.build());
    }
  }

  /** The intent opening SESSION, named NAME, in the app, or just the app. */
  private PendingIntent openIntent(String session, String name) {
    Intent open = new Intent(this, MainActivity.class)
        .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
    if (session != null) {
      open.putExtra(MainActivity.EXTRA_SESSION, session)
          .putExtra(MainActivity.EXTRA_NAME, name);
    }
    return PendingIntent.getActivity(this, Notifications.idFor(session), open,
        PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
  }

  private synchronized void setStatus(String text) {
    if (text.equals(status)) {
      return;
    }
    status = text;
    getSystemService(NotificationManager.class).notify(WATCHING_ID, watching(text));
  }

  private Notification watching(String text) {
    Intent open = new Intent(this, MainActivity.class)
        .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
    return new Notification.Builder(this, Notifications.CHANNEL_WATCHING)
        .setSmallIcon(R.drawable.ic_notification)
        .setContentTitle(text)
        .setOngoing(true)
        .setContentIntent(PendingIntent.getActivity(this, 0, open,
            PendingIntent.FLAG_IMMUTABLE))
        .build();
  }
}
