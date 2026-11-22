package net.stafforini.agentremote;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Resumes listening for notifications after the phone restarts. */
public class BootReceiver extends BroadcastReceiver {
  @Override
  public void onReceive(Context context, Intent intent) {
    if (Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())
        || Intent.ACTION_MY_PACKAGE_REPLACED.equals(intent.getAction())) {
      Notifications.sync(context);
    }
  }
}
