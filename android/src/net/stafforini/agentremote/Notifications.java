package net.stafforini.agentremote;

import android.Manifest;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.media.AudioAttributes;
import android.media.RingtoneManager;

/**
 * The notification mode the user picked with the page's bell button, and
 * what the app needs to know to honor it.
 *
 * <p>The mode is "off", "visual" (a banner without sound or vibration) or
 * "sound" (a banner with the default notification sound and vibration).
 * Android ties sound to a notification channel, so each mode posts to its
 * own channel.
 */
final class Notifications {
  static final String OFF = "off";
  static final String VISUAL = "visual";
  static final String SOUND = "sound";

  static final String CHANNEL_WATCHING = "watching";
  static final String CHANNEL_VISUAL = "sessions-visual";
  static final String CHANNEL_SOUND = "sessions-sound";

  static final String PREFS = "agent-remote";
  static final String KEY_URL = "url";
  private static final String KEY_MODE = "notify";

  /** Whether the page is on screen, and the session it shows, if any. */
  static volatile boolean appVisible;
  static volatile String viewing;

  private Notifications() { }

  static SharedPreferences prefs(Context c) {
    return c.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
  }

  static String mode(Context c) {
    String m = prefs(c).getString(KEY_MODE, OFF);
    return VISUAL.equals(m) || SOUND.equals(m) ? m : OFF;
  }

  static void setMode(Context c, String mode) {
    prefs(c).edit().putString(KEY_MODE, mode).apply();
  }

  static boolean permitted(Context c) {
    return c.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
        == PackageManager.PERMISSION_GRANTED;
  }

  /** Start or stop the watching service to match the saved mode. */
  static void sync(Context c) {
    Intent service = new Intent(c, NotifyService.class);
    if (!OFF.equals(mode(c)) && permitted(c)
        && prefs(c).getString(KEY_URL, null) != null) {
      c.startForegroundService(service);
    } else {
      c.stopService(service);
    }
  }

  /** Notification id of SESSION's latest notification. */
  static int idFor(String session) {
    // 1 is the watching notification's.
    int id = session == null ? 2 : session.hashCode();
    return id == 1 ? 3 : id;
  }

  /** Remove SESSION's notification, now that the user is looking at it. */
  static void dismiss(Context c, String session) {
    c.getSystemService(NotificationManager.class).cancel(idFor(session));
  }

  static void createChannels(Context c) {
    NotificationManager nm = c.getSystemService(NotificationManager.class);
    NotificationChannel watching = new NotificationChannel(CHANNEL_WATCHING,
        "Watching sessions", NotificationManager.IMPORTANCE_MIN);
    watching.setDescription("Shown while the app listens for sessions that need you.");
    watching.setShowBadge(false);
    nm.createNotificationChannel(watching);

    NotificationChannel visual = new NotificationChannel(CHANNEL_VISUAL,
        "Sessions (silent)", NotificationManager.IMPORTANCE_HIGH);
    visual.setDescription("A session needs you; banner only.");
    visual.setSound(null, null);
    visual.enableVibration(false);
    nm.createNotificationChannel(visual);

    NotificationChannel sound = new NotificationChannel(CHANNEL_SOUND,
        "Sessions (sound)", NotificationManager.IMPORTANCE_HIGH);
    sound.setDescription("A session needs you; banner, sound and vibration.");
    sound.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION),
        new AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build());
    sound.enableVibration(true);
    nm.createNotificationChannel(sound);
  }
}
