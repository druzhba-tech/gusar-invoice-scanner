package tj.gusar.invoice_scanner

import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val INSTALLER_CHANNEL = "tj.gusar.invoice_scanner/app_installer"
    private val SHARED_FILES_CHANNEL = "tj.gusar.invoice_scanner/shared_files"
    private var downloadReceiver: BroadcastReceiver? = null
    private var sharedFilesChannel: MethodChannel? = null
    private var pendingSharedPaths: MutableList<String> = mutableListOf()
    private var activeDownloadId: Long = -1L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIncomingShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingShareIntent(intent)
        if (pendingSharedPaths.isNotEmpty() && sharedFilesChannel != null) {
            val pathsToDeliver = ArrayList(pendingSharedPaths)
            pendingSharedPaths.clear()
            sharedFilesChannel?.invokeMethod("onSharedFiles", pathsToDeliver)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        sharedFilesChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARED_FILES_CHANNEL)
        sharedFilesChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialSharedFiles" -> {
                    val pathsToDeliver = ArrayList(pendingSharedPaths)
                    pendingSharedPaths.clear()
                    result.success(pathsToDeliver)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INSTALLER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath != null) {
                        try {
                            installApkFile(File(filePath))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INSTALL_ERROR", e.message, null)
                        }
                    } else {
                        result.error("INVALID_PATH", "File path is null", null)
                    }
                }
                "startSystemDownload" -> {
                    val url = call.argument<String>("url")
                    val title = call.argument<String>("title") ?: "GScan Обновление"
                    val description = call.argument<String>("description") ?: "Скачивание новой версии..."
                    val fileName = call.argument<String>("fileName") ?: "Gusar-Scanner.apk"

                    if (url != null) {
                        try {
                            val downloadId = startSystemDownload(url, title, description, fileName)
                            result.success(downloadId)
                        } catch (e: Exception) {
                            result.error("DOWNLOAD_ERROR", e.message, null)
                        }
                    } else {
                        result.error("INVALID_URL", "URL is null", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun handleIncomingShareIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action ?: return
        val type = intent.type ?: ""
        if (!type.startsWith("image/") && type != "application/pdf") return

        val uris = mutableListOf<Uri>()
        if (action == Intent.ACTION_SEND) {
            val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(Intent.EXTRA_STREAM)
            }
            if (uri != null) uris.add(uri)
        } else if (action == Intent.ACTION_SEND_MULTIPLE) {
            val list = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            }
            if (list != null) uris.addAll(list)
        }

        for (uri in uris) {
            val copiedPath = copySharedUriToCache(uri, type)
            if (copiedPath != null) {
                pendingSharedPaths.add(copiedPath)
            }
        }
    }

    private fun copySharedUriToCache(uri: Uri, fallbackMime: String): String? {
        return try {
            val mime = contentResolver.getType(uri) ?: fallbackMime
            val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
                ?: if (mime == "application/pdf") "pdf" else "jpg"
            val outFile = File(cacheDir, "shared_invoice_${System.currentTimeMillis()}_${pendingSharedPaths.size}.$ext")
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(outFile).use { output ->
                    input.copyTo(output)
                }
            } ?: return null
            outFile.absolutePath
        } catch (e: Exception) {
            null
        }
    }

    private fun startSystemDownload(url: String, title: String, description: String, fileName: String): Long {
        val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager

        // 1. Проверяем, нет ли уже активной или ожидающей загрузки этого файла в системе
        try {
            val query = DownloadManager.Query()
            val cursor = dm.query(query)
            if (cursor != null) {
                val uriIdx = cursor.getColumnIndex(DownloadManager.COLUMN_URI)
                val statusIdx = cursor.getColumnIndex(DownloadManager.COLUMN_STATUS)
                val idIdx = cursor.getColumnIndex(DownloadManager.COLUMN_ID)
                val titleIdx = cursor.getColumnIndex(DownloadManager.COLUMN_TITLE)

                while (cursor.moveToNext()) {
                    val status = if (statusIdx != -1) cursor.getInt(statusIdx) else -1
                    val itemUri = if (uriIdx != -1) cursor.getString(uriIdx) else null
                    val itemTitle = if (titleIdx != -1) cursor.getString(titleIdx) else null

                    if (status == DownloadManager.STATUS_RUNNING || status == DownloadManager.STATUS_PENDING) {
                        val isSameUrl = itemUri != null && itemUri == url
                        val isSameApp = itemTitle != null && itemTitle.contains("GScan")
                        if (isSameUrl || isSameApp) {
                            val existingId = if (idIdx != -1) cursor.getLong(idIdx) else -1L
                            cursor.close()
                            activeDownloadId = existingId
                            registerDownloadReceiver()
                            return existingId
                        }
                    }
                }
                cursor.close()
            }
        } catch (e: Exception) {}

        // 2. Удаляем старый файл, если он остался от прошлых загрузок
        try {
            val destFile = File(getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), fileName)
            if (destFile.exists()) {
                destFile.delete()
            }
        } catch (e: Exception) {}

        val request = DownloadManager.Request(Uri.parse(url))
            .setTitle(title)
            .setDescription(description)
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            .setAllowedOverMetered(true)
            .setAllowedOverRoaming(true)
            .setDestinationInExternalFilesDir(this, Environment.DIRECTORY_DOWNLOADS, fileName)

        val downloadId = dm.enqueue(request)
        activeDownloadId = downloadId
        registerDownloadReceiver()
        return downloadId
    }

    private fun registerDownloadReceiver() {
        if (downloadReceiver != null) return

        downloadReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (DownloadManager.ACTION_DOWNLOAD_COMPLETE == intent?.action) {
                    val id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L)
                    // Устанавливаем строго только наш собственный загруженный APK!
                    if (activeDownloadId != -1L && id == activeDownloadId) {
                        val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
                        val query = DownloadManager.Query().setFilterById(id)
                        val cursor = dm.query(query)
                        if (cursor != null && cursor.moveToFirst()) {
                            val statusIdx = cursor.getColumnIndex(DownloadManager.COLUMN_STATUS)
                            if (statusIdx != -1 && cursor.getInt(statusIdx) == DownloadManager.STATUS_SUCCESSFUL) {
                                val uri = dm.getUriForDownloadedFile(id)
                                if (uri != null) {
                                    promptInstallFromUri(uri)
                                }
                            }
                            cursor.close()
                        }
                        activeDownloadId = -1L
                    }
                }
            }
        }

        val filter = IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE)
        if (Build.VERSION.SDK_INT >= 33) {
            try {
                registerReceiver(downloadReceiver, filter, Context.RECEIVER_EXPORTED)
            } catch (e: Exception) {
                registerReceiver(downloadReceiver, filter)
            }
        } else {
            registerReceiver(downloadReceiver, filter)
        }
    }

    private fun promptInstallFromUri(uri: Uri) {
        try {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
        } catch (e: Exception) {}
    }

    private fun installApkFile(file: File) {
        val intent = Intent(Intent.ACTION_VIEW)
        val uri: Uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            FileProvider.getUriForFile(
                this,
                "${applicationContext.packageName}.fileprovider",
                file
            )
        } else {
            Uri.fromFile(file)
        }
        intent.setDataAndType(uri, "application/vnd.android.package-archive")
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        startActivity(intent)
    }

    override fun onDestroy() {
        super.onDestroy()
        downloadReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (e: Exception) {}
            downloadReceiver = null
        }
    }
}
