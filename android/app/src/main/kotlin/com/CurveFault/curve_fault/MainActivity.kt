package com.CurveFault.curve_fault

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Base64
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.RandomAccessFile
import java.security.SecureRandom
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "curve_fault/storage"
        private const val TAG_LENGTH = 16
        private const val REQUEST_PICK_FILES = 1201
        private const val REQUEST_PICK_FOLDER = 1202
        private const val REQUEST_SAVE_AS = 1203
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val random = SecureRandom()
    private var pendingPickResult: MethodChannel.Result? = null
    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSaveSource: String? = null

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQUEST_PICK_FILES -> handlePickFilesResult(resultCode, data)
            REQUEST_PICK_FOLDER -> handlePickFolderResult(resultCode, data)
            REQUEST_SAVE_AS -> handleSaveAsResult(resultCode, data)
        }
    }

    private fun handlePickFilesResult(resultCode: Int, data: Intent?) {
        val pending = pendingPickResult ?: return
        pendingPickResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            pending.success(emptyList<Map<String, Any?>>())
            return
        }
        val uris = mutableListOf<Uri>()
        data.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) {
                clip.getItemAt(i)?.uri?.let { uris.add(it) }
            }
        }
        data.data?.let { uris.add(it) }
        persistPermissions(uris, data.flags)
        runBackground(pending) { uris.map { describeUri(it) } }
    }

    private fun handlePickFolderResult(resultCode: Int, data: Intent?) {
        val pending = pendingPickResult ?: return
        pendingPickResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pending.success(null)
            return
        }
        persistPermissions(listOf(uri), data.flags)
        runBackground(pending) { describeTree(uri) }
    }

    private fun handleSaveAsResult(resultCode: Int, data: Intent?) {
        val pending = pendingSaveResult ?: return
        val source = pendingSaveSource
        pendingSaveResult = null
        pendingSaveSource = null
        val target = data?.data
        if (resultCode != Activity.RESULT_OK || target == null || source == null) {
            pending.success(null)
            return
        }
        runBackground(pending) {
            contentResolver.openOutputStream(target, "wt")?.use { output ->
                File(source).inputStream().use { input ->
                    input.copyTo(output, 64 * 1024)
                }
            } ?: throw IOException("Could not open the selected destination")
            target.toString()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickFiles" -> launchPickFiles(result)
                    "pickFolder" -> launchPickFolder(result)
                    "listDocuments" -> {
                        val treeUri = call.argument<String>("treeUri")
                        val recursive = call.argument<Boolean>("recursive") ?: true
                        if (treeUri == null) {
                            result.error("bad_args", "Missing treeUri", null)
                        } else {
                            runBackground(result) { listDocuments(Uri.parse(treeUri), recursive) }
                        }
                    }
                    "describeDocument" -> {
                        val uri = call.argument<String>("uri")
                        if (uri == null) result.error("bad_args", "Missing uri", null)
                        else runBackground(result) { describeUri(Uri.parse(uri)) }
                    }
                    "copyDocumentToFile" -> {
                        val uri = call.argument<String>("uri")
                        val path = call.argument<String>("path")
                        val maxBytes = (call.argument<Number>("maxBytes"))?.toLong() ?: -1L
                        if (uri == null || path == null) {
                            result.error("bad_args", "Missing uri or path", null)
                        } else {
                            runBackground(result) {
                                copyDocumentToFile(Uri.parse(uri), path, maxBytes)
                                null
                            }
                        }
                    }
                    "replaceDocument" -> {
                        val uri = call.argument<String>("uri")
                        val containerPath = call.argument<String>("containerPath")
                        val backupPath = call.argument<String>("backupPath")
                        val displayName = call.argument<String>("displayName")
                        if (uri == null || containerPath == null || backupPath == null || displayName == null) {
                            result.error("bad_args", "Missing replace arguments", null)
                        } else {
                            runBackground(result) {
                                replaceDocument(
                                    Uri.parse(uri),
                                    containerPath,
                                    backupPath,
                                    displayName,
                                )
                            }
                        }
                    }
                    "deleteDocument" -> {
                        val uri = call.argument<String>("uri")
                        if (uri == null) result.error("bad_args", "Missing uri", null)
                        else runBackground(result) {
                            deleteDocument(Uri.parse(uri))
                            true
                        }
                    }
                    "saveAs" -> launchSaveAs(call, result)
                    "shareFile" -> {
                        val path = call.argument<String>("sourcePath")
                        val mime = call.argument<String>("mime") ?: "application/octet-stream"
                        if (path == null) result.error("bad_args", "Missing sourcePath", null)
                        else runBackground(result) {
                            shareFile(path, mime)
                            null
                        }
                    }
                    "openFile" -> {
                        val path = call.argument<String>("sourcePath")
                        val mime = call.argument<String>("mime") ?: "application/octet-stream"
                        if (path == null) result.error("bad_args", "Missing sourcePath", null)
                        else runBackground(result) {
                            openFile(path, mime)
                            null
                        }
                    }
                    "encryptChunks" -> {
                        val inputPath = call.argument<String>("inputPath")
                        val outputPath = call.argument<String>("outputPath")
                        val key = decodeKey(call.argument<String>("key"))
                        val headerHash = decodeKey(call.argument<String>("headerHash"))
                        val chunkSize = call.argument<Int>("chunkSize")
                        val append = call.argument<Boolean>("append") ?: false
                        if (inputPath == null || outputPath == null || key == null ||
                            headerHash == null || chunkSize == null
                        ) {
                            result.error("bad_args", "Missing cipher arguments", null)
                        } else {
                            runBackground(result) {
                                encryptChunks(inputPath, outputPath, key, headerHash, chunkSize, append)
                                null
                            }
                        }
                    }
                    "decryptChunks" -> {
                        val containerPath = call.argument<String>("containerPath")
                        val outputPath = call.argument<String>("outputPath")
                        val key = decodeKey(call.argument<String>("key"))
                        val headerHash = decodeKey(call.argument<String>("headerHash"))
                        val plaintextLength = call.argument<Number>("plaintextLength")?.toLong()
                        val chunkSize = call.argument<Int>("chunkSize")
                        val chunkOffset = call.argument<Number>("chunkOffset")?.toLong()
                        if (containerPath == null || outputPath == null || key == null ||
                            headerHash == null || plaintextLength == null ||
                            chunkSize == null || chunkOffset == null
                        ) {
                            result.error("bad_args", "Missing cipher arguments", null)
                        } else {
                            runBackground(result) {
                                decryptChunks(
                                    containerPath,
                                    outputPath,
                                    key,
                                    headerHash,
                                    plaintextLength,
                                    chunkSize,
                                    chunkOffset,
                                    true,
                                )
                                null
                            }
                        }
                    }
                    "verifyChunks" -> {
                        val containerPath = call.argument<String>("containerPath")
                        val key = decodeKey(call.argument<String>("key"))
                        val headerHash = decodeKey(call.argument<String>("headerHash"))
                        val plaintextLength = call.argument<Number>("plaintextLength")?.toLong()
                        val chunkSize = call.argument<Int>("chunkSize")
                        val chunkOffset = call.argument<Number>("chunkOffset")?.toLong()
                        if (containerPath == null || key == null || headerHash == null ||
                            plaintextLength == null || chunkSize == null || chunkOffset == null
                        ) {
                            result.error("bad_args", "Missing cipher arguments", null)
                        } else {
                            runBackground(result) {
                                decryptChunks(
                                    containerPath,
                                    "",
                                    key,
                                    headerHash,
                                    plaintextLength,
                                    chunkSize,
                                    chunkOffset,
                                    false,
                                )
                                null
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        executor.shutdownNow()
        super.onDestroy()
    }

    private fun runBackground(result: MethodChannel.Result, block: () -> Any?) {
        executor.execute {
            try {
                val value = block()
                runOnUiThread { result.success(value) }
            } catch (error: Throwable) {
                Log.e("CurveFault", "storage operation failed", error)
                runOnUiThread {
                    result.error(
                        "storage_error",
                        error.message ?: error.javaClass.simpleName,
                        null,
                    )
                }
            }
        }
    }

    private fun launchPickFiles(result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error("picker_busy", "A picker is already open", null)
            return
        }
        pendingPickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
        }
        try {
            startActivityForResult(intent, REQUEST_PICK_FILES)
        } catch (error: Exception) {
            pendingPickResult = null
            result.error("picker_error", error.message, null)
        }
    }

    private fun launchPickFolder(result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error("picker_busy", "A picker is already open", null)
            return
        }
        pendingPickResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
            )
        }
        try {
            startActivityForResult(intent, REQUEST_PICK_FOLDER)
        } catch (error: Exception) {
            pendingPickResult = null
            result.error("picker_error", error.message, null)
        }
    }

    private fun launchSaveAs(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>("sourcePath")
        val displayName = call.argument<String>("displayName") ?: "file"
        val mime = call.argument<String>("mime") ?: "application/octet-stream"
        if (sourcePath == null) {
            result.error("bad_args", "Missing sourcePath", null)
            return
        }
        if (pendingSaveResult != null) {
            result.error("picker_busy", "A save dialog is already open", null)
            return
        }
        pendingSaveResult = result
        pendingSaveSource = sourcePath
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mime
            putExtra(Intent.EXTRA_TITLE, displayName)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }
        try {
            startActivityForResult(intent, REQUEST_SAVE_AS)
        } catch (error: Exception) {
            pendingSaveResult = null
            pendingSaveSource = null
            result.error("picker_error", error.message, null)
        }
    }

    private fun persistPermissions(uris: List<Uri>, intentFlags: Int) {
        val granted = intentFlags and (
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        if (granted == 0) return
        for (uri in uris) {
            try {
                contentResolver.takePersistableUriPermission(uri, granted)
            } catch (_: SecurityException) {
                // Some providers do not support persisted grants. The URI stays
                // usable for the current process.
            } catch (_: Exception) {
                // Ignore providers that reject persisted grants.
            }
        }
    }

    private fun describeTree(uri: Uri): Map<String, Any?> {
        val doc = try {
            DocumentFile.fromTreeUri(this, uri)
        } catch (_: Exception) {
            null
        }
        val name = doc?.name ?: uri.lastPathSegment ?: "Folder"
        return mapOf(
            "uri" to uri.toString(),
            "name" to name,
            "mime" to DocumentsContract.Document.MIME_TYPE_DIR,
            "size" to 0L,
            "relativePath" to name,
            "parentUri" to "",
            "lastModified" to 0L,
            "isDirectory" to true,
            "canWrite" to true,
        )
    }

    private fun describeUri(uri: Uri): Map<String, Any?> {
        var name: String? = null
        var mime: String? = null
        var size = 0L
        var lastModified = 0L
        var relativePath = ""
        var canWrite = false
        try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex >= 0) name = cursor.getString(nameIndex)
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                        size = cursor.getLong(sizeIndex)
                    }
                    val mimeIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                    if (mimeIndex >= 0) mime = cursor.getString(mimeIndex)
                    val modifiedIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                    if (modifiedIndex >= 0 && !cursor.isNull(modifiedIndex)) {
                        lastModified = cursor.getLong(modifiedIndex)
                    }
                    val pathIndex = cursor.getColumnIndex("relative_path")
                    if (pathIndex >= 0 && !cursor.isNull(pathIndex)) {
                        relativePath = cursor.getString(pathIndex) ?: ""
                    }
                    val flagsIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_FLAGS)
                    if (flagsIndex >= 0) {
                        canWrite = (cursor.getLong(flagsIndex) and
                            DocumentsContract.Document.FLAG_SUPPORTS_WRITE.toLong()) != 0L
                    }
                }
            }
        } catch (_: Exception) {
            // Fall back to the URI itself.
        }
        if (name.isNullOrEmpty()) name = uri.lastPathSegment ?: "Unknown"
        if (mime.isNullOrEmpty()) mime = contentResolver.getType(uri) ?: guessMime(name)
        if (relativePath.isEmpty()) relativePath = name
        val isDirectory = mime == DocumentsContract.Document.MIME_TYPE_DIR
        return mapOf(
            "uri" to uri.toString(),
            "name" to name,
            "mime" to mime,
            "size" to size,
            "relativePath" to relativePath,
            "parentUri" to "",
            "lastModified" to lastModified,
            "isDirectory" to isDirectory,
            "canWrite" to canWrite,
        )
    }

    private fun listDocuments(treeUri: Uri, recursive: Boolean): List<Map<String, Any?>> {
        val root = DocumentFile.fromTreeUri(this, treeUri)
            ?: throw IOException("The selected folder is not accessible")
        val results = mutableListOf<Map<String, Any?>>()
        walk(root, "", recursive, results)
        return results
    }

    private fun walk(
        directory: DocumentFile,
        path: String,
        recursive: Boolean,
        results: MutableList<Map<String, Any?>>,
    ) {
        val children = try {
            directory.listFiles()
        } catch (_: Exception) {
            return
        }
        for (child in children) {
            val name = child.name ?: continue
            val childPath = if (path.isEmpty()) name else "$path/$name"
            val mime = child.type ?: guessMime(name)
            val isDirectory = child.isDirectory ||
                mime == DocumentsContract.Document.MIME_TYPE_DIR
            results.add(
                mapOf(
                    "uri" to child.uri.toString(),
                    "name" to name,
                    "mime" to mime,
                    "size" to if (isDirectory) 0L else child.length(),
                    "relativePath" to childPath,
                    "parentUri" to directory.uri.toString(),
                    "lastModified" to child.lastModified(),
                    "isDirectory" to isDirectory,
                    "canWrite" to child.canWrite(),
                ),
            )
            if (recursive && isDirectory) {
                walk(child, childPath, recursive, results)
            }
        }
    }

    private fun copyDocumentToFile(uri: Uri, path: String, maxBytes: Long) {
        val target = File(path)
        target.parentFile?.mkdirs()
        val input = contentResolver.openInputStream(uri)
            ?: throw IOException("Could not open the source document")
        input.use { source ->
            FileOutputStream(target).use { output ->
                val buffer = ByteArray(64 * 1024)
                var total = 0L
                while (true) {
                    val read = source.read(buffer)
                    if (read <= 0) break
                    var toWrite = read
                    if (maxBytes > 0 && total + read > maxBytes) {
                        toWrite = (maxBytes - total).toInt()
                    }
                    if (toWrite > 0) {
                        output.write(buffer, 0, toWrite)
                        total += toWrite
                    }
                    if (maxBytes > 0 && total >= maxBytes) break
                }
                output.flush()
            }
        }
    }

    private fun replaceDocument(
        uri: Uri,
        containerPath: String,
        backupPath: String,
        displayName: String,
    ): Map<String, Any?> {
        val original = describeUri(uri)
        val originalName = original["name"] as String
        val oldPath = resolveMediaPath(uri)
        var renamedUri: Uri? = null
        var wroteContainer = false

        try {
            // Write the container while the original URI grant is still valid.
            val output = contentResolver.openOutputStream(uri, "wt")
                ?: throw IOException("Could not open the locked file for writing")
            output.use { target ->
                File(containerPath).inputStream().use { source ->
                    source.copyTo(target, 64 * 1024)
                }
                target.flush()
            }
            wroteContainer = true

            // Rename last so no provider access is needed on the new document
            // while the old URI is still the one covered by our grant.
            renamedUri = try {
                DocumentsContract.renameDocument(contentResolver, uri, displayName)
            } catch (_: Exception) {
                null
            }
            if (renamedUri == null) {
                throw IOException("This location does not allow renaming files")
            }

            // Keep the tree-form URI so the persisted folder grant still
            // covers the renamed document after the app restarts.
            val resultUri = if (DocumentsContract.isTreeUri(uri)) {
                val newDocId = DocumentsContract.getDocumentId(renamedUri)
                DocumentsContract.buildDocumentUriUsingTree(uri, newDocId)
            } else {
                renamedUri
            }

            // Best effort for plain document URIs. Tree/prefix grants already
            // cover child documents.
            try {
                contentResolver.takePersistableUriPermission(
                    resultUri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
            } catch (_: Exception) {
                // Ignore providers that refuse a persistable grant.
            }

            val newPath = oldPath?.let { path ->
                File(path).parentFile?.let { File(it, displayName).absolutePath }
            }
            refreshMedia(oldPath, newPath)
            return mapOf(
                "uri" to resultUri.toString(),
                "name" to displayName,
                "size" to File(containerPath).length(),
            )
        } catch (error: Throwable) {
            // The plaintext backup is still in app-private storage. Try to put
            // the original bytes and name back before surfacing the failure.
            if (wroteContainer) {
                try {
                    contentResolver.openOutputStream(uri, "wt")?.use { target ->
                        File(backupPath).inputStream().use { source ->
                            source.copyTo(target, 64 * 1024)
                        }
                        target.flush()
                    }
                } catch (_: Exception) {
                    // Best effort only.
                }
            }
            if (renamedUri != null) {
                try {
                    DocumentsContract.renameDocument(
                        contentResolver,
                        renamedUri,
                        originalName,
                    )
                } catch (_: Exception) {
                    // Best effort only.
                }
            }
            if (oldPath != null) {
                refreshMedia(oldPath, oldPath)
            }
            throw error
        }
    }

    private fun deleteDocument(uri: Uri) {
        val deleted = try {
            DocumentsContract.deleteDocument(contentResolver, uri)
        } catch (_: Exception) {
            false
        }
        if (deleted) return
        val fallback = try {
            DocumentFile.fromSingleUri(this, uri)?.delete() ?: false
        } catch (_: Exception) {
            false
        }
        if (!fallback) {
            throw IOException("Could not delete the encrypted file")
        }
    }

    private fun shareFile(path: String, mime: String) {
        val file = File(path)
        if (!file.exists()) throw IOException("The decrypted file is missing")
        val uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file,
        )
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = mime
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipData = android.content.ClipData.newRawUri(file.name, uri)
        }
        try {
            startActivity(Intent.createChooser(intent, "Share ${file.name}"))
        } catch (error: ActivityNotFoundException) {
            throw IOException("No app can share this file", error)
        }
    }

    private fun openFile(path: String, mime: String) {
        val file = File(path)
        if (!file.exists()) throw IOException("The decrypted file is missing")
        val uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipData = android.content.ClipData.newRawUri(file.name, uri)
        }
        try {
            startActivity(intent)
        } catch (error: ActivityNotFoundException) {
            throw IOException("No app can open this file", error)
        }
    }

    private fun refreshMedia(vararg paths: String?) {
        val files = paths.filterNotNull().filter { it.isNotEmpty() }.distinct()
        if (files.isEmpty()) return
        try {
            MediaScannerConnection.scanFile(
                this,
                files.toTypedArray(),
                null,
                null,
            )
        } catch (_: Exception) {
            // Gallery cleanup is best effort.
        }
    }

    private fun resolveMediaPath(uri: Uri): String? {
        try {
            val authority = uri.authority ?: return null
            if (authority == "com.android.externalstorage.documents") {
                val documentId = DocumentsContract.getDocumentId(uri)
                val separator = documentId.indexOf(':')
                if (separator <= 0) return null
                val volume = documentId.substring(0, separator)
                val relative = Uri.decode(documentId.substring(separator + 1))
                val root = if (volume.equals("primary", ignoreCase = true)) {
                    Environment.getExternalStorageDirectory().absolutePath
                } else {
                    "/storage/$volume"
                }
                return "$root/$relative"
            }
            if (authority == "com.android.providers.media.documents") {
                val documentId = DocumentsContract.getDocumentId(uri)
                val id = documentId.substringAfter(':', documentId)
                if (id.isNotEmpty() && id.all { it.isDigit() }) {
                    contentResolver.query(
                        MediaStore.Files.getContentUri("external"),
                        arrayOf(MediaStore.MediaColumns.DATA),
                        MediaStore.MediaColumns._ID + "=?",
                        arrayOf(id),
                        null,
                    )?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            return cursor.getString(0)
                        }
                    }
                }
            }
        } catch (_: Exception) {
            // The provider may not expose a real path.
        }
        return null
    }

    private fun guessMime(name: String): String {
        val extension = name.substringAfterLast('.', "").lowercase()
        if (extension.isEmpty()) return "application/octet-stream"
        return MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(extension)
            ?: "application/octet-stream"
    }

    private fun decodeKey(value: String?): ByteArray? {
        if (value == null) return null
        return try {
            Base64.decode(value, Base64.NO_WRAP)
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    private fun encryptChunks(
        inputPath: String,
        outputPath: String,
        key: ByteArray,
        headerHash: ByteArray,
        chunkSize: Int,
        append: Boolean,
    ) {
        val plaintext = File(inputPath)
        if (!plaintext.exists()) throw IOException("Input file is missing")
        val buffer = ByteArray(chunkSize)
        plaintext.inputStream().buffered(64 * 1024).use { input ->
            FileOutputStream(outputPath, append).buffered(64 * 1024).use { output ->
                var index = 0L
                while (true) {
                    val length = readChunk(input, buffer, chunkSize)
                    if (length <= 0) break
                    val nonce = ByteArray(12)
                    random.nextBytes(nonce)
                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                    cipher.init(
                        Cipher.ENCRYPT_MODE,
                        SecretKeySpec(key, "AES"),
                        GCMParameterSpec(128, nonce),
                    )
                    cipher.updateAAD(chunkAad(headerHash, index))
                    val encrypted = cipher.doFinal(buffer, 0, length)
                    val ciphertextLength = encrypted.size - TAG_LENGTH
                    output.write(nonce)
                    output.write(intToLeBytes(ciphertextLength))
                    output.write(encrypted, 0, ciphertextLength)
                    output.write(encrypted, ciphertextLength, TAG_LENGTH)
                    index++
                }
                output.flush()
            }
        }
    }

    private fun decryptChunks(
        containerPath: String,
        outputPath: String,
        key: ByteArray,
        headerHash: ByteArray,
        plaintextLength: Long,
        chunkSize: Int,
        chunkOffset: Long,
        writeOutput: Boolean,
    ) {
        RandomAccessFile(containerPath, "r").use { input ->
            input.seek(chunkOffset)
            val output = if (writeOutput) {
                FileOutputStream(outputPath).buffered(64 * 1024)
            } else {
                null
            }
            try {
                var index = 0L
                var total = 0L
                while (true) {
                    val nonce = readExact(input, 12) ?: break
                    val lengthBytes = readExact(input, 4)
                        ?: throw IOException("Corrupt chunk length")
                    val ciphertextLength = leBytesToInt(lengthBytes)
                    if (ciphertextLength < 0 || ciphertextLength > chunkSize) {
                        throw IOException("Invalid chunk length")
                    }
                    val ciphertext = readExact(input, ciphertextLength)
                        ?: throw IOException("Corrupt chunk")
                    val tag = readExact(input, TAG_LENGTH)
                        ?: throw IOException("Corrupt chunk tag")
                    val combined = ByteArray(ciphertextLength + TAG_LENGTH)
                    System.arraycopy(ciphertext, 0, combined, 0, ciphertextLength)
                    System.arraycopy(tag, 0, combined, ciphertextLength, TAG_LENGTH)

                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                    cipher.init(
                        Cipher.DECRYPT_MODE,
                        SecretKeySpec(key, "AES"),
                        GCMParameterSpec(128, nonce),
                    )
                    cipher.updateAAD(chunkAad(headerHash, index))
                    val plaintext = cipher.doFinal(combined)
                    output?.write(plaintext)
                    total += plaintext.size.toLong()
                    index++
                }
                if (total != plaintextLength) {
                    throw IOException("Container is truncated or padded")
                }
                output?.flush()
            } finally {
                output?.close()
            }
        }
    }

    private fun readChunk(input: InputStream, buffer: ByteArray, length: Int): Int {
        var offset = 0
        while (offset < length) {
            val read = input.read(buffer, offset, length - offset)
            if (read < 0) break
            offset += read
        }
        return offset
    }

    private fun readExact(input: RandomAccessFile, length: Int): ByteArray? {
        if (length == 0) return ByteArray(0)
        val buffer = ByteArray(length)
        var offset = 0
        while (offset < length) {
            val read = input.read(buffer, offset, length - offset)
            if (read < 0) {
                if (offset == 0) return null
                throw IOException("Unexpected end of container")
            }
            offset += read
        }
        return buffer
    }

    private fun chunkAad(headerHash: ByteArray, index: Long): ByteArray {
        val aad = ByteArray(headerHash.size + 8)
        System.arraycopy(headerHash, 0, aad, 0, headerHash.size)
        var value = index
        for (i in 0 until 8) {
            aad[headerHash.size + i] = (value and 0xFF).toByte()
            value = value ushr 8
        }
        return aad
    }

    private fun intToLeBytes(value: Int): ByteArray {
        return byteArrayOf(
            (value and 0xFF).toByte(),
            ((value ushr 8) and 0xFF).toByte(),
            ((value ushr 16) and 0xFF).toByte(),
            ((value ushr 24) and 0xFF).toByte(),
        )
    }

    private fun leBytesToInt(bytes: ByteArray): Int {
        return (bytes[0].toInt() and 0xFF) or
            ((bytes[1].toInt() and 0xFF) shl 8) or
            ((bytes[2].toInt() and 0xFF) shl 16) or
            ((bytes[3].toInt() and 0xFF) shl 24)
    }
}
