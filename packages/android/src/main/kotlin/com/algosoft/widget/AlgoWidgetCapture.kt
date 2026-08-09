package com.algosoft.widget

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.view.View
import java.io.File

/**
 * Native capture for the Algo Widget (docs/PROTOCOL.md).
 *
 * THE SCOPE RULE FOR THIS FILE: only what cannot be done above the platform.
 * The interaction trace, the wire protocol, the crash throttles and the report
 * UI all live in the Flutter and React Native packages, where they can be
 * tested without a device. What is left here is screen capture, audio,
 * screenshots — and each of those is a place where the platform, not this SDK,
 * decides what the user is asked.
 *
 * FOUR THINGS THE PLATFORM DECIDES, and which no amount of API design here can
 * soften — they are documented rather than worked around because a customer's
 * security review will ask about all four:
 *
 *  1. MediaProjection captures THE WHOLE DEVICE, not this app. Anything on
 *     screen during a recording is in the recording, including notification
 *     banners and whatever the reporter switches to. Android 15's partial
 *     (single-app) capture is preferred wherever available and is what
 *     [preferSingleApp] asks for.
 *  2. The system consent dialog fires on EVERY start. There is no "remember
 *     this" and there must not be: a recording the user did not just approve is
 *     not one they consented to.
 *  3. From Android 14 the capture must run in a foreground service with a
 *     visible notification, declared `mediaProjection`. The notification is not
 *     a nuisance to be minimised — it is the only indicator the reporter has
 *     once the app is in the background.
 *  4. Our own recording controls are IN the recording. `MediaProjection` reads
 *     the real display, so unlike the web widget's `[data-algo-private]` there
 *     is no way to exclude our own UI from the frame. The alternative — driving
 *     stop/pause from the notification shade only — is offered by
 *     [controlsInNotification] rather than assumed.
 */
class AlgoWidgetCapture(private val context: Context) {

    /** Where a finished recording lands. App-private by construction: nothing
     *  this SDK writes is readable by another app, and nothing leaves the
     *  device until the reporter presses Send. */
    private val outputDir: File get() = File(context.cacheDir, "algo-widget").apply { mkdirs() }

    private var projection: MediaProjection? = null
    private var recorder: MediaRecorder? = null

    /**
     * Build the intent that shows the system consent dialog.
     *
     * Returned rather than launched, because the result has to come back to an
     * Activity the host owns. An SDK that started its own Activity to hide this
     * step would be hiding the consent gate.
     */
    fun screenCaptureIntent(): Intent {
        val manager =
            context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        return manager.createScreenCaptureIntent()
    }

    /** True when the device can offer single-app capture rather than the whole
     *  screen — the safer default, and worth telling the reporter about. */
    val preferSingleApp: Boolean
        get() = Build.VERSION.SDK_INT >= 35

    /** Whether stop/pause should live in the notification instead of on screen.
     *  On by default from Android 14, where the foreground service already puts
     *  a persistent notification there anyway. */
    var controlsInNotification: Boolean = Build.VERSION.SDK_INT >= 34

    /**
     * Audio-only narration.
     *
     * `.m4a` deliberately: AAC-in-MP4 is what MediaRecorder writes natively AND
     * what the transcription service accepts by name, so a voice note makes it
     * from the phone to a transcript with no re-encode anywhere. Writing `.aac`
     * or `.3gp` instead costs a server-side transcode for nothing.
     */
    fun startVoice(): File {
        val file = File(outputDir, "voice-${System.currentTimeMillis()}.m4a")
        val rec =
            if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else @Suppress("DEPRECATION") MediaRecorder()
        rec.apply {
            setAudioSource(MediaRecorder.AudioSource.MIC)
            setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            setAudioEncodingBitRate(64_000)
            setAudioSamplingRate(44_100)
            setOutputFile(file.absolutePath)
            prepare()
            start()
        }
        recorder = rec
        return file
    }

    fun stopVoice() {
        recorder?.runCatching {
            stop()
            release()
        }
        recorder = null
    }

    /**
     * A screenshot of the host's own window.
     *
     * NOT MediaProjection: capturing one window needs no consent dialog and no
     * foreground service, and it cannot see another app. A screenshot is the
     * cheapest useful evidence there is, and making it cost the full
     * whole-device consent flow would mean most reporters attach nothing.
     *
     * Returns null rather than throwing — evidence going missing must never
     * block a report.
     */
    fun screenshot(activity: Activity): File? = runCatching {
        val view: View = activity.window.decorView.rootView
        val bitmap = android.graphics.Bitmap.createBitmap(
            view.width,
            view.height,
            android.graphics.Bitmap.Config.ARGB_8888,
        )
        android.graphics.Canvas(bitmap).also { view.draw(it) }
        val file = File(outputDir, "shot-${System.currentTimeMillis()}.png")
        file.outputStream().use {
            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
        }
        file
    }.getOrNull()

    /** Release everything. Called on stop AND on cancel — a cancel that left a
     *  projection alive would leave the system's recording indicator on, which
     *  tells the user something is being captured when nothing is. */
    fun release() {
        stopVoice()
        projection?.stop()
        projection = null
    }

    /** Delete everything this SDK has written. Cancel must guarantee that
     *  nothing recorded ever left the device — and that nothing stays on it. */
    fun purge() {
        outputDir.listFiles()?.forEach { it.delete() }
    }
}
