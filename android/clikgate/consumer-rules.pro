# Clikgate Android SDK consumer rules.
# The public API needs no keep rules (it is called directly by app code).

# WorkManager instantiates the flush worker reflectively by class name (persisted in its DB).
-keep class com.clikgate.internal.FlushWorker { <init>(android.content.Context, androidx.work.WorkerParameters); }

# Play Integrity is optional (compileOnly); referenced only after a runtime class check.
-dontwarn com.google.android.play.core.integrity.**
-dontwarn com.google.android.gms.tasks.**

# Firebase Analytics is optional: the SDK calls it by reflection when the app ships it.
-keep class com.google.firebase.analytics.FirebaseAnalytics {
    public static com.google.firebase.analytics.FirebaseAnalytics getInstance(android.content.Context);
    public void logEvent(java.lang.String, android.os.Bundle);
    public void setUserProperty(java.lang.String, java.lang.String);
    public com.google.android.gms.tasks.Task getAppInstanceId();
}
-keep interface com.google.android.gms.tasks.OnCompleteListener { *; }
-keepclassmembers class * extends com.google.android.gms.tasks.Task {
    public com.google.android.gms.tasks.Task addOnCompleteListener(com.google.android.gms.tasks.OnCompleteListener);
    public boolean isSuccessful();
    public java.lang.Object getResult();
}
-dontwarn com.google.firebase.analytics.**
