package com.clikgate.internal

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import com.clikgate.Clikgate
import java.util.concurrent.TimeUnit

/** Schedules an offline retry of the event queue flush. */
internal fun interface BackgroundScheduler {
    fun scheduleFlush()
}

/** WorkManager one-off flush with a network-connected constraint (unique, keeps existing). */
internal class WorkManagerScheduler(private val context: Context) : BackgroundScheduler {
    override fun scheduleFlush() {
        try {
            val request = OneTimeWorkRequest.Builder(FlushWorker::class.java)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(WORK_NAME, ExistingWorkPolicy.KEEP, request)
        } catch (t: Throwable) {
            // WorkManager not initialised (custom init disabled by the app) - retried on next launch.
            Log.w("Could not schedule background flush: ${t.javaClass.simpleName}")
        }
    }

    companion object {
        const val WORK_NAME = "com.clikgate.flush"
    }
}

/** Flushes queued events once the device is online. */
internal class FlushWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val core = Clikgate.coreOrNull() ?: return Result.success()
        return when (core.flushBlocking(timeoutMs = 60_000)) {
            true -> Result.success()
            false -> if (runAttemptCount < 5) Result.retry() else Result.success()
        }
    }
}
