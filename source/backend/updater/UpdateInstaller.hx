package backend.updater;

import backend.updater.UpdateManager.UpdateInfo;
#if sys
import sys.io.File;
import sys.FileSystem;
import haxe.io.Path;
import haxe.io.Bytes;
import openfl.net.URLLoader;
import openfl.net.URLRequest;
import openfl.net.URLLoaderDataFormat;
import openfl.utils.ByteArray;
import openfl.events.Event;
import openfl.events.ProgressEvent;
import openfl.events.IOErrorEvent;
import openfl.events.SecurityErrorEvent;
#end

using StringTools;

typedef StagedFile = {src:String, target:String};

#if (windows && cpp)
@:cppFileCode('extern "C" __declspec(dllimport) int __stdcall MoveFileExW(const wchar_t*, const wchar_t*, unsigned long);
extern "C" __declspec(dllimport) unsigned long __stdcall GetLastError(void);
extern "C" __declspec(dllimport) unsigned long __stdcall GetCurrentProcessId(void);
extern "C" __declspec(dllimport) void* __stdcall OpenProcess(unsigned long, int, unsigned long);
extern "C" __declspec(dllimport) unsigned long __stdcall WaitForSingleObject(void*, unsigned long);
extern "C" __declspec(dllimport) int __stdcall CloseHandle(void*);')
#elseif (cpp && !windows)
@:cppFileCode('#include <unistd.h>
#include <signal.h>')
#end

/**
 * Manages the download, verification, staging, and installation of application updates.
 * Handles SHA-256 verification, ZIP extraction, file replacement with rollback, and elevation handling.
 */
class UpdateInstaller {
	public static var DIR_TMP:String = 'update_tmp';
	public static var DIR_STAGING:String = 'update_staging';
	public static var BAK_SUFFIX:String = '.old.bak';
	static var MARKER_READY:String = '.ready'; // written into staging once extraction succeeds
	static var MARKER_PID:String = '.parent_pid'; // PID of the session that staged the update
	static var MARKER_TRIES:String = '.attempts'; // how many boots have tried to install this staging
	static var LOG_FAILURE:String = 'update_error.txt'; // written next to the exe when an install is abandoned
	static var MAX_APPLY_TRIES:Int = 3;

	static var SKIP_PREFIXES:Array<String> = ['mods/', 'update_tmp/', 'update_staging/'];
	static var SKIP_FILES:Array<String> = ['modslist.txt']; // user data: which mods the player enabled

	#if sys
	final info:UpdateInfo;

	final mutex:sys.thread.Mutex = new sys.thread.Mutex();
	var _phase:String = 'idle';
	var _percent:Float = 0;
	var _error:String = null;
	var _ready:Bool = false;
	var _needElevation:Bool = false;
	var _logs:Array<String> = [];

	var root:String;
	var tmpDir:String;
	var stageDir:String;
	var sumsText:String;
	var zipBytes:Bytes;

	/**
	 * Creates a new UpdateInstaller instance.
	 * @param info The update information containing download URLs and checksums
	 */
	public function new(info:UpdateInfo) {
		this.info = info;
	}

	/**
	 * The .app bundle the running build lives in, or null when this build is not one.
	 * @return The absolute path of the bundle directory, or null
	 */
	static function bundlePath():String {
		#if mac
		// Sys.programPath() is <bundle>/Contents/MacOS/<exe>, so the bundle is three levels up.
		var bundle:String = Path.directory(Path.directory(Path.directory(Sys.programPath())));
		if (bundle != null && bundle.toLowerCase().endsWith('.app'))
			return bundle;
		#end
		return null;
	}

	/**
	 * The folder an update installs into: the one holding the executable, or on macOS the one
	 * holding the .app bundle, since there the whole bundle is what gets replaced.
	 * @return The absolute path of the install root
	 */
	static function installRoot():String {
		var bundle:String = bundlePath();
		return (bundle != null) ? Path.directory(bundle) : Path.directory(Sys.programPath());
	}

	public function start():Void {
		root = installRoot();
		tmpDir = Path.join([root, DIR_TMP]);
		stageDir = Path.join([root, DIR_STAGING]);

		log('Update ${info.tag} selected.');
		if (info.zipUrl == null) {
			fail('Release has no build for this platform to download.');
			return;
		}
		if (info.zipSha256 == null && info.sumsUrl == null) {
			fail('Release has no checksum (GitHub digest or SHA256SUMS.txt) -- refusing to install an unverified build.');
			return;
		}
		if (!isWritable(root)) {
			// Asked before the download rather than after it: on macOS the install root is usually
			// /Applications, and there is no point pulling several hundred megabytes to find out.
			log('Install folder is not writable (needs administrator/root?).');
			mutex.acquire();
			_needElevation = true;
			mutex.release();
			setPhase('need-elevation');
			return;
		}

		try {
			recreateDir(tmpDir);
			recreateDir(stageDir);
		} catch (e:Dynamic) {
			fail('Could not prepare staging folders: ${Std.string(e)}');
			return;
		}

		if (info.zipSha256 != null) {
			log('Using GitHub-provided SHA-256.');
			downloadZip();
		} else {
			downloadSums();
		}
	}

	/**
	 * Gets the current phase of the update process.
	 * @return The current phase identifier
	 */
	public function phase():String
		return guarded(() -> _phase);

	/**
	 * Gets the current download progress as a fraction.
	 * @return Progress between 0.0 and 1.0
	 */
	public function percent():Float
		return guarded(() -> _percent);

	/**
	 * Gets the error message if the update failed.
	 * @return The error message, or null if no error occurred
	 */
	public function error():String
		return guarded(() -> _error);

	/**
	 * Checks if the update is ready to be applied.
	 * @return True if staging is complete and ready for installation
	 */
	public function isReady():Bool
		return guarded(() -> _ready);

	/**
	 * Checks if admin/elevation is required to complete the installation.
	 * @return True if the install folder is not writable
	 */
	public function needsElevation():Bool
		return guarded(() -> _needElevation);

	/**
	 * Retrieves and clears accumulated log messages.
	 * @return An array of new log messages since the last call
	 */
	public function popLogs():Array<String> {
		mutex.acquire();
		var out = _logs;
		_logs = [];
		mutex.release();
		return out;
	}

	/**
	 * Relaunches the application after update installation is complete.
	 */
	public function relaunch():Void {
		spawnSelf();
		Sys.exit(0);
	}

	/**
	 * Starts a fresh copy of this build and leaves it running on its own.
	 * On macOS the bundle is handed to `open` so the new instance comes up as an application
	 * rather than as a bare child process with no Dock entry of its own.
	 */
	static function spawnSelf():Void {
		try {
			#if mac
			var bundle:String = bundlePath();
			if (bundle != null) {
				Sys.command('open', ['-n', bundle]);
				return;
			}
			#end
			new sys.io.Process(Sys.programPath(), []);
		} catch (e:Dynamic) {}
	}

	/**
	 * Downloads the SHA256SUMS.txt file from the release.
	 */
	function downloadSums():Void {
		setPhase('download-sums');
		log('Downloading checksums...');
		httpBinary(info.sumsUrl, false, function(bytes:Bytes) {
			sumsText = bytes.toString();
			downloadZip();
		});
	}

	/**
	 * Downloads the update ZIP file from the release.
	 */
	function downloadZip():Void {
		setPhase('downloading');
		setPercent(0);
		log('Downloading ${info.zipName}...');
		httpBinary(info.zipUrl, true, function(bytes:Bytes) {
			zipBytes = bytes;
			log('Download complete (${fmtMB(bytes.length)}).');
			startWorker();
		});
	}

	/**
	 * Downloads binary data from a URL with optional progress tracking.
	 * @param url The URL to download from
	 * @param trackProgress Whether to report download progress
	 * @param onDone Callback invoked with the downloaded bytes
	 */
	function httpBinary(url:String, trackProgress:Bool, onDone:Bytes->Void):Void {
		var loader = new URLLoader();
		loader.dataFormat = URLLoaderDataFormat.BINARY;
		if (trackProgress) {
			loader.addEventListener(ProgressEvent.PROGRESS, function(e:ProgressEvent) {
				if (e.bytesTotal > 0)
					setPercent(e.bytesLoaded / e.bytesTotal);
			});
		}
		loader.addEventListener(Event.COMPLETE, function(_) {
			var ba:ByteArray = loader.data;
			var bytes:Bytes = ba;
			onDone(bytes);
		});
		loader.addEventListener(IOErrorEvent.IO_ERROR, function(e:IOErrorEvent) fail('Download failed: ${e.text}'));
		loader.addEventListener(SecurityErrorEvent.SECURITY_ERROR, function(e:SecurityErrorEvent) fail('Download blocked: ${e.text}'));
		try
			loader.load(new URLRequest(url))
		catch (e:Dynamic)
			fail('Could not start download: ${Std.string(e)}');
	}

	/**
	 * Starts the background worker thread for verification and extraction.
	 */
	function startWorker():Void {
		sys.thread.Thread.create(function() {
			try {
				setPhase('verifying');
				log('Verifying SHA-256...');
				var actual:String = haxe.crypto.Sha256.make(zipBytes).toHex().toLowerCase();
				var expected:String = (info.zipSha256 != null) ? info.zipSha256 : expectedHashFor(info.zipName, sumsText);
				if (expected == null)
					throw 'No checksum listed for ${info.zipName}.';
				if (actual != expected.toLowerCase())
					throw 'Checksum mismatch -- the download is corrupt or tampered with.';
				log('Checksum OK.');

				setPhase('extracting');
				log('Extracting...');
				ensureDir(tmpDir);
				var localZip:String = Path.join([tmpDir, Path.withoutDirectory(info.zipName)]);
				File.saveBytes(localZip, zipBytes);
				zipBytes = null; // the archive lives on disk now -- don't hold a second copy in memory
				extractZip(localZip, stageDir);
				forceDelete(localZip);

				File.saveContent(Path.join([stageDir, MARKER_READY]), 'ready');
				File.saveContent(Path.join([stageDir, MARKER_PID]), Std.string(currentPid()));
				log('Update staged. Restarting to finish install...');

				mutex.acquire();
				_ready = true;
				mutex.release();
				setPhase('ready');
			} catch (e:Dynamic) {
				fail(Std.string(e));
			}
		});
	}

	/**
	 * Extracts a ZIP file to the destination directory, reading it back from disk and releasing
	 * each entry once it lands, so a multi-hundred-megabyte build is never held in memory
	 * compressed and uncompressed at the same time.
	 * @param zipPath The path of the downloaded archive
	 * @param dest The destination directory path
	 */
	function extractZip(zipPath:String, dest:String):Void {
		var input:sys.io.FileInput = File.read(zipPath, true);
		var entries:haxe.ds.List<haxe.zip.Entry> = null;
		try {
			entries = haxe.zip.Reader.readZip(input);
			input.close();
		} catch (e:Dynamic) {
			try
				input.close()
			catch (e2:Dynamic) {}
			throw e;
		}

		for (entry in entries) {
			if (entry.fileName == null || entry.fileName.endsWith('/'))
				continue;
			var rel:String = entry.fileName.split('\\').join('/');
			var outPath:String = Path.join([dest, rel]);
			ensureDir(Path.directory(outPath));
			File.saveBytes(outPath, haxe.zip.Reader.unzip(entry));
			entry.data = null;
		}

		#if !windows
		restoreUnixModes(zipPath, dest);
		ensureMainExecutable(effectiveBuildRoot(dest));
		#end
	}

	#if !windows
	/**
	 * Restores the executable bits the archive recorded.
	 * A zip keeps Unix permissions in the central directory's external attributes, and
	 * haxe.zip.Reader never reads those -- it stops at the first central directory record -- so
	 * every extracted file lands under the umask and the game's own binary comes out unrunnable.
	 * @param zipPath The archive that was extracted
	 * @param dest The directory it was extracted into
	 */
	function restoreUnixModes(zipPath:String, dest:String):Void {
		var wanted:Array<String> = [];
		try {
			wanted = zipExecutables(zipPath);
		} catch (e:Dynamic) {
			log('Could not read permissions from the archive: ${Std.string(e)}');
			return;
		}

		var paths:Array<String> = [];
		for (rel in wanted) {
			var p:String = Path.join([dest, rel]);
			if (FileSystem.exists(p))
				paths.push(p);
		}
		if (paths.length == 0)
			return;

		var at:Int = 0;
		while (at < paths.length) {
			var chunk:Array<String> = paths.slice(at, at + 128); // keep well inside the argument limit
			chunk.unshift('+x');
			Sys.command('chmod', chunk);
			at += 128;
		}
		log('Restored the executable bit on ${paths.length} file(s).');
	}

	/**
	 * Reads the archive's central directory and lists the entries whose recorded Unix mode has
	 * any execute bit set.
	 * @param zipPath The archive to read
	 * @return The relative paths of the executable entries
	 */
	function zipExecutables(zipPath:String):Array<String> {
		var out:Array<String> = [];
		var f:sys.io.FileInput = File.read(zipPath, true);
		try {
			var size:Int = FileSystem.stat(zipPath).size;
			var scan:Int = (size < 66000) ? size : 66000; // 64K comment cap plus the record itself
			f.seek(size - scan, SeekBegin);
			var tail:Bytes = f.read(scan);

			var eocd:Int = -1;
			var i:Int = tail.length - 22;
			while (i >= 0) {
				if (tail.get(i) == 0x50 && tail.get(i + 1) == 0x4B && tail.get(i + 2) == 0x05 && tail.get(i + 3) == 0x06) {
					eocd = i;
					break;
				}
				i--;
			}
			if (eocd < 0)
				throw 'no end-of-central-directory record';

			var count:Int = tail.getUInt16(eocd + 10);
			var cdOffset:Int = tail.getInt32(eocd + 16);
			if (count == 0xFFFF || cdOffset == -1)
				throw 'zip64 archives are not read here';

			f.seek(cdOffset, SeekBegin);
			for (n in 0...count) {
				if (f.readInt32() != 0x02014B50)
					break;
				f.seek(24, SeekCur); // version, flags, method, time, crc, both sizes
				var nameLen:Int = f.readUInt16();
				var extraLen:Int = f.readUInt16();
				var commentLen:Int = f.readUInt16();
				f.seek(4, SeekCur); // start disk, internal attributes
				var external:Int = f.readInt32();
				f.seek(4, SeekCur); // local header offset
				var name:String = f.readString(nameLen);
				f.seek(extraLen + commentLen, SeekCur);

				var mode:Int = (external >> 16) & 0xFFFF;
				if ((mode & 73) != 0 && !name.endsWith('/')) // 73 = 0o111
					out.push(name.split('\\').join('/'));
			}
		} catch (e:Dynamic) {
			try
				f.close()
			catch (e2:Dynamic) {}
			throw e;
		}
		f.close();
		return out;
	}

	/**
	 * Guarantees the game's own binary comes out of the archive executable even when the archive
	 * recorded no Unix permissions at all, which is what a zip built on Windows carries.
	 * @param buildRoot The extracted build's root directory
	 */
	function ensureMainExecutable(buildRoot:String):Void {
		var exe:String = Path.withoutDirectory(Sys.programPath());
		var candidates:Array<String> = [Path.join([buildRoot, exe])];

		var bundle:String = bundlePath();
		if (bundle != null)
			candidates.push(Path.join([buildRoot, Path.withoutDirectory(bundle), 'Contents', 'MacOS', exe]));

		for (p in candidates)
			if (FileSystem.exists(p))
				Sys.command('chmod', ['+x', p]);
	}
	#end

	/**
	 * Determines the effective build root directory, unwrapping single-directory zips.
	 * The staging markers are written after extraction, so counting them made a wrapped build
	 * look like three entries and the wrapper was never unwrapped -- every file, the executable
	 * included, then got installed one folder too deep.
	 * @param dir The directory to check
	 * @return The build root directory path
	 */
	static function effectiveBuildRoot(dir:String):String {
		var cur:String = dir;
		var depth:Int = 0;
		while (depth++ < 3) {
			var items:Array<String> = [];
			for (name in FileSystem.readDirectory(cur))
				if (name != MARKER_READY && name != MARKER_PID && name != MARKER_TRIES)
					items.push(name);

			if (items.length != 1)
				break;

			var only:String = Path.join([cur, items[0]]);
			// A bundle is the build, not a folder wrapped around one, so stop at it.
			if (!FileSystem.isDirectory(only) || items[0].toLowerCase().endsWith('.app'))
				break;
			cur = only;
		}
		return cur;
	}

	/**
	 * Collects every staged file that should be installed, as source/target pairs.
	 * @param srcRoot The staged update source directory
	 * @param dstRoot The destination root directory
	 * @return The files to install, in walk order
	 */
	static function collectStaged(srcRoot:String, dstRoot:String):Array<StagedFile> {
		#if mac
		var bundleName:String = stagedBundleName(srcRoot);
		if (bundleName != null)
			return bundleSwap(srcRoot, dstRoot, bundleName);
		#end

		var out:Array<StagedFile> = [];
		function walk(dir:String) {
			for (name in FileSystem.readDirectory(dir)) {
				if (name == MARKER_READY || name == MARKER_PID || name == MARKER_TRIES)
					continue;
				var full:String = Path.join([dir, name]);
				var rel:String = relativeTo(srcRoot, full).split('\\').join('/');
				var relLow:String = rel.toLowerCase();
				if (relLow.endsWith(BAK_SUFFIX) || isSkipped(relLow))
					continue;
				if (FileSystem.isDirectory(full))
					walk(full);
				else
					out.push({src: full, target: Path.join([dstRoot, rel])});
			}
		}
		walk(srcRoot);
		return out;
	}

	#if mac
	/**
	 * The name of the .app bundle a staged macOS build consists of, or null when the staging does
	 * not hold one.
	 * @param srcRoot The staged update source directory
	 * @return The bundle's directory name, or null
	 */
	static function stagedBundleName(srcRoot:String):String {
		for (name in FileSystem.readDirectory(srcRoot))
			if (name.toLowerCase().endsWith('.app') && FileSystem.isDirectory(Path.join([srcRoot, name])))
				return name;
		return null;
	}

	/**
	 * The moves that install a macOS build. The bundle is replaced whole rather than file by
	 * file, so nothing of the old build is left inside it, and the player's own files are then
	 * carried across out of the bundle the swap moved aside.
	 * @param srcRoot The staged update source directory
	 * @param dstRoot The destination root directory
	 * @param bundleName The bundle's directory name
	 * @return The moves to perform, in order
	 */
	static function bundleSwap(srcRoot:String, dstRoot:String, bundleName:String):Array<StagedFile> {
		var installed:String = Path.join([dstRoot, bundleName]);
		var out:Array<StagedFile> = [{src: Path.join([srcRoot, bundleName]), target: installed}];

		// After that swap the old bundle sits at <bundle>.old.bak, so the player's mods can be
		// moved out of it and into the build that replaced it. Both halves go through the same
		// journal, so a failure here rolls the bundle swap back too.
		var displaced:String = installed + BAK_SUFFIX;
		for (rel in ['Contents/Resources/mods', 'Contents/Resources/modsList.txt'])
			if (FileSystem.exists(Path.join([installed, rel])))
				out.push({src: Path.join([displaced, rel]), target: Path.join([installed, rel])});

		return out;
	}
	#end

	/**
	 * Applies staged update files from source to destination, replacing existing files.
	 * The install is all-or-nothing: a file that cannot be swapped rolls every earlier file back,
	 * so one locked DLL can no longer abort the walk part-way and leave the build carrying new
	 * assets and the old executable -- which sorts last in the walk and was therefore the file
	 * most likely to be missed.
	 * @param srcRoot The staged update source directory
	 * @param dstRoot The destination root directory
	 * @return The number of files replaced
	 */
	static function applyStaged(srcRoot:String, dstRoot:String):Int {
		var files:Array<StagedFile> = collectStaged(srcRoot, dstRoot);
		var done:Array<StagedFile> = [];
		for (f in files) {
			try {
				replaceFile(f.src, f.target);
			} catch (e:Dynamic) {
				rollback(done);
				throw e;
			}
			done.push(f);
		}
		return done.length;
	}

	/**
	 * Undoes an interrupted install: returns each file already placed back to the staging folder
	 * and restores the backup it displaced, leaving the running build exactly as it was.
	 * @param done The files installed so far, in the order they were installed
	 */
	static function rollback(done:Array<StagedFile>):Void {
		var i:Int = done.length;
		while (i-- > 0) {
			var f:StagedFile = done[i];
			var bak:String = f.target + BAK_SUFFIX;
			try {
				if (FileSystem.exists(f.target))
					moveReplace(f.target, f.src);
				if (FileSystem.exists(bak))
					moveReplace(bak, f.target);
			} catch (e:Dynamic) {}
		}
	}

	/**
	 * Replaces a target file with a source file, creating a backup with .old.bak extension.
	 * If the replacement cannot be put in place the backup is moved back first, so a failure
	 * never leaves the target missing altogether.
	 * @param src The source file to copy from
	 * @param target The target file to replace
	 */
	static function replaceFile(src:String, target:String):Void {
		ensureDir(Path.directory(target));
		var bak:String = target + BAK_SUFFIX;
		var movedAside:Bool = false;
		if (FileSystem.exists(target)) {
			if (!moveWithRetry(target, bak)) {
				clearReadOnly(target);
				if (!moveWithRetry(target, bak))
					throw 'Could not move "$target" aside (Windows error $lastWinErr). It may be locked by another program or antivirus.';
			}
			movedAside = true;
		}
		if (!moveWithRetry(src, target)) {
			clearReadOnly(src);
			if (!moveWithRetry(src, target)) {
				var err:Int = lastWinErr;
				if (movedAside)
					moveReplace(bak, target);
				throw 'Could not install "$target" (Windows error $err).';
			}
		}
	}

	public static var lastWinErr:Int = 0;

	/**
	 * Attempts to move a file using platform-specific methods.
	 * On Windows, uses MoveFileEx for atomic operations. On other platforms, uses standard rename.
	 * @param src The source file path
	 * @param dst The destination file path
	 * @return True if the move succeeded
	 */
	static function moveReplace(src:String, dst:String):Bool {
		#if windows
		var r:Int = 0;
		var err:Int = 0;
		untyped __cpp__('hx::strbuf _s; hx::strbuf _d; {0} = MoveFileExW({1}.wchar_str(&_s), {2}.wchar_str(&_d), 0x3) ? 1 : 0; {3} = {0} ? 0 : (int)GetLastError();',
			r, src, dst, err);
		lastWinErr = err;
		return r != 0;
		#else
		try {
			sys.FileSystem.rename(src, dst);
			return true;
		} catch (e:Dynamic)
			return false;
		#end
	}

	/**
	 * Retries file move operation with backoff while the file is still held by something else.
	 * Retries up to 40 times with 0.25s sleep between attempts for ERROR_SHARING_VIOLATION (32)
	 * and ERROR_ACCESS_DENIED (5) -- the latter is what a virus scanner reports while it still
	 * has a freshly written file open.
	 * @param src The source file path
	 * @param dst The destination file path
	 * @return True if the move succeeded
	 */
	static function moveWithRetry(src:String, dst:String):Bool {
		var tries:Int = 0;
		while (true) {
			if (moveReplace(src, dst))
				return true;
			if ((lastWinErr != 32 && lastWinErr != 5) || tries >= 40)
				return false;
			tries++;
			#if sys Sys.sleep(0.25); #end
		}
	}

	/**
	 * Gets the current process ID.
	 * On Windows, calls GetCurrentProcessId(). On other platforms, returns 0.
	 * @return The current process ID, or 0 on non-Windows platforms
	 */
	static function currentPid():Int {
		#if windows
		var pid:Int = 0;
		untyped __cpp__('{0} = (int)GetCurrentProcessId()', pid);
		return pid;
		#elseif cpp
		var pid:Int = 0;
		untyped __cpp__('{0} = (int)getpid()', pid);
		return pid;
		#else
		return 0;
		#end
	}

	/**
	 * Waits for a process to exit.
	 * On Windows, opens the process and waits up to the specified timeout.
	 * @param pid The process ID to wait for
	 * @param timeoutMs Maximum time to wait in milliseconds
	 */
	static function waitForPidExit(pid:Int, timeoutMs:Int):Void {
		if (pid <= 0)
			return;
		#if windows
		untyped __cpp__('void* _h = OpenProcess(0x00100000, 0, (unsigned long){0}); _h ? (WaitForSingleObject(_h, (unsigned long){1}), CloseHandle(_h)) : 0',
			pid, timeoutMs);
		#elseif cpp
		// Polled rather than waited on: the process that staged the update is this one's parent,
		// so waitpid does not apply to it.
		var waited:Int = 0;
		while (waited < timeoutMs) {
			var alive:Int = 0;
			untyped __cpp__('{0} = (::kill((pid_t){1}, 0) == 0) ? 1 : 0', alive, pid);
			if (alive == 0)
				return;
			Sys.sleep(0.05);
			waited += 50;
		}
		#end
	}

	/**
	 * Forcefully deletes a file, clearing read-only attributes if necessary.
	 * @param p The file path to delete
	 */
	static function forceDelete(p:String):Void {
		try
			FileSystem.deleteFile(p)
		catch (e:Dynamic) {
			clearReadOnly(p);
			try
				FileSystem.deleteFile(p)
			catch (e2:Dynamic) {}
		}
	}

	/**
	 * Clears the read-only attribute from a file on Windows.
	 * Uses `attrib -R` command on Windows; no-op on other platforms.
	 * @param p The file path
	 */
	static function clearReadOnly(p:String):Void {
		#if windows
		try
			Sys.command('attrib', ['-R', p])
		catch (e:Dynamic) {}
		#else
		try
			Sys.command('chmod', ['u+w', p])
		catch (e:Dynamic) {}
		#end
	}

	/**
	 * Checks if a directory is writable by attempting to create and delete a probe file.
	 * @param dir The directory path to test
	 * @return True if the directory is writable
	 */
	function isWritable(dir:String):Bool {
		var probe:String = Path.join([dir, '.psych_update_probe']);
		try {
			File.saveContent(probe, 'ok');
			FileSystem.deleteFile(probe);
			return true;
		} catch (e:Dynamic) {
			return false;
		}
	}

	/**
	 * Checks if a relative path should be skipped during update application.
	 * @param relLow The lowercase relative path
	 * @return True if the path matches any skip prefixes (mods/, update_tmp/, update_staging/)
	 */
	static function isSkipped(relLow:String):Bool {
		for (p in SKIP_PREFIXES)
			if (relLow == p.substr(0, p.length - 1) || relLow.startsWith(p))
				return true;
		for (f in SKIP_FILES)
			if (relLow == f)
				return true;
		return false;
	}

	/**
	 * Computes a relative path from a root directory to a full path.
	 * @param root The root directory path
	 * @param full The full file path
	 * @return The relative path from root to full
	 */
	static function relativeTo(root:String, full:String):String {
		var r:String = root.split('\\').join('/');
		var f:String = full.split('\\').join('/');
		if (!r.endsWith('/'))
			r += '/';
		return f.startsWith(r) ? f.substr(r.length) : f;
	}

	/**
	 * Parses a SHA256SUMS.txt file to find the expected hash for a given file name.
	 * @param fileName The file name to look up (basename)
	 * @param sums The SHA256SUMS.txt file contents
	 * @return The expected SHA-256 hash, or null if not found
	 */
	function expectedHashFor(fileName:String, sums:String):String {
		if (sums == null)
			return null;
		var base:String = Path.withoutDirectory(fileName).toLowerCase();
		for (line in sums.split('\n')) {
			var t:String = line.trim();
			if (t.length == 0)
				continue;
			var sp:Int = t.indexOf(' ');
			if (sp <= 0)
				continue;
			var hash:String = t.substr(0, sp).trim();
			var name:String = t.substr(sp).trim();
			if (name.startsWith('*'))
				name = name.substr(1);
			if (Path.withoutDirectory(name).toLowerCase() == base)
				return hash;
		}
		return null;
	}

	/**
	 * Ensures a directory exists, creating it if necessary.
	 * @param dir The directory path
	 */
	static function ensureDir(dir:String):Void {
		if (dir != null && dir.length > 0 && !FileSystem.exists(dir))
			FileSystem.createDirectory(dir);
	}

	/**
	 * Recreates a directory by deleting and re-creating it.
	 * @param dir The directory path to recreate
	 */
	function recreateDir(dir:String):Void {
		if (FileSystem.exists(dir))
			deleteTree(dir);
		FileSystem.createDirectory(dir);
	}

	/**
	 * Recursively deletes a directory or file.
	 * @param dir The path to delete (file or directory)
	 */
	static function deleteTree(dir:String):Void {
		if (!FileSystem.exists(dir))
			return;
		if (FileSystem.isDirectory(dir)) {
			for (name in FileSystem.readDirectory(dir))
				deleteTree(Path.join([dir, name]));
			try
				FileSystem.deleteDirectory(dir)
			catch (e:Dynamic) {}
		} else {
			try
				FileSystem.deleteFile(dir)
			catch (e:Dynamic) {}
		}
	}

	/**
	 * Formats a byte count as a megabyte string with one decimal place.
	 * @param bytes The number of bytes
	 * @return A formatted string like "12.5 MB"
	 */
	inline function fmtMB(bytes:Int):String
		return '${Math.round(bytes / 1048576 * 10) / 10} MB';

	/**
	 * Appends a message to the log, thread-safe.
	 * @param msg The message to log
	 */
	function log(msg:String):Void {
		mutex.acquire();
		_logs.push(msg);
		mutex.release();
	}

	/**
	 * Sets the current update phase, thread-safe.
	 * @param p The phase identifier
	 */
	function setPhase(p:String):Void {
		mutex.acquire();
		_phase = p;
		mutex.release();
	}

	/**
	 * Sets the current download progress, thread-safe.
	 * @param p Progress as a fraction between 0.0 and 1.0
	 */
	function setPercent(p:Float):Void {
		mutex.acquire();
		_percent = p;
		mutex.release();
	}

	/**
	 * Records an error and sets the phase to 'error', thread-safe.
	 * @param msg The error message
	 */
	function fail(msg:String):Void {
		mutex.acquire();
		_error = msg;
		_phase = 'error';
		_logs.push('ERROR: $msg');
		mutex.release();
	}

	/**
	 * Executes a closure while holding the mutex lock.
	 * @param f The closure to execute
	 * @return The result of the closure
	 */
	function guarded<T>(f:Void->T):T {
		mutex.acquire();
		var v = f();
		mutex.release();
		return v;
	}

	/**
	 * Applies any pending staged update on application startup.
	 * Waits for the previous process to exit, applies files, and relaunches the application.
	 * A failed install keeps the staging so the next boot retries it, up to MAX_APPLY_TRIES, and
	 * writes what went wrong to update_error.txt beside the executable instead of discarding the
	 * download and booting the old build without a word.
	 */
	public static function applyPendingOnBoot():Void {
		var root:String = installRoot();
		var staging:String = Path.join([root, DIR_STAGING]);
		if (!FileSystem.exists(Path.join([staging, MARKER_READY])))
			return;

		var tries:Int = readTries(staging) + 1;
		if (tries > MAX_APPLY_TRIES) {
			writeFailureLog(root,
				'Gave up after $MAX_APPLY_TRIES attempts to install the staged update. The download has been discarded -- please update manually.');
			deleteTree(staging);
			return;
		}
		try
			File.saveContent(Path.join([staging, MARKER_TRIES]), Std.string(tries))
		catch (e:Dynamic) {}

		try {
			var pidFile:String = Path.join([staging, MARKER_PID]);
			if (FileSystem.exists(pidFile)) {
				var pid:Null<Int> = Std.parseInt(File.getContent(pidFile).trim());
				if (pid != null)
					waitForPidExit(pid, 20000);
			}

			applyStaged(effectiveBuildRoot(staging), root);
		} catch (e:Dynamic) {
			writeFailureLog(root, Std.string(e));
			return;
		}

		forceDelete(Path.join([staging, MARKER_READY])); // drop the marker first: a half-deleted staging must not re-apply
		deleteTree(staging);
		forceDelete(Path.join([root, LOG_FAILURE]));

		spawnSelf();
		Sys.exit(0);
	}

	/**
	 * Reads how many boots have already tried to install the staged update.
	 * @param staging The staging directory path
	 * @return The recorded attempt count, or 0 when there is none
	 */
	static function readTries(staging:String):Int {
		try {
			var f:String = Path.join([staging, MARKER_TRIES]);
			if (FileSystem.exists(f)) {
				var n:Null<Int> = Std.parseInt(File.getContent(f).trim());
				if (n != null)
					return n;
			}
		} catch (e:Dynamic) {}
		return 0;
	}

	/**
	 * Records why an install was abandoned, beside the executable, so the failure is visible
	 * instead of the game quietly booting on the old build.
	 * @param root The install root directory
	 * @param msg The failure message
	 */
	static function writeFailureLog(root:String, msg:String):Void {
		try
			File.saveContent(Path.join([root, LOG_FAILURE]), 'The staged update could not be installed.\n\n$msg\n')
		catch (e:Dynamic) {}
	}

	/**
	 * Cleans up temporary and incomplete update files on startup.
	 * Removes backup files (.old.bak) from previous installations.
	 */
	public static function cleanupOnBoot():Void {
		var root:String = installRoot();
		deleteTree(Path.join([root, DIR_TMP]));
		var staging:String = Path.join([root, DIR_STAGING]);
		if (FileSystem.exists(staging) && !FileSystem.exists(Path.join([staging, MARKER_READY])))
			deleteTree(staging);

		var bundle:String = bundlePath();
		if (bundle != null) {
			// The install root is whatever folder the bundle sits in -- /Applications, say -- so
			// only the bundle and the one the last swap displaced are ours to sweep.
			var displaced:String = bundle + BAK_SUFFIX;
			if (FileSystem.exists(displaced))
				deleteTree(displaced);
			deleteBaks(bundle);
		} else {
			deleteBaks(root);
		}
	}

	/**
	 * Recursively deletes backup files (.old.bak) from a directory tree.
	 * A backup whose original is missing is put back instead of deleted -- an install that failed
	 * and could not fully roll itself back leaves those behind, and they are the only copy.
	 * @param dir The directory to clean
	 */
	static function deleteBaks(dir:String):Void {
		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir))
			return;
		for (name in FileSystem.readDirectory(dir)) {
			if (name == 'mods')
				continue;
			var full:String = Path.join([dir, name]);
			try {
				if (name.toLowerCase().endsWith(BAK_SUFFIX)) {
					var original:String = full.substr(0, full.length - BAK_SUFFIX.length);
					if (!FileSystem.exists(original))
						moveReplace(full, original);
					else if (FileSystem.isDirectory(full))
						deleteTree(full);
					else
						forceDelete(full);
				} else if (FileSystem.isDirectory(full)) {
					deleteBaks(full);
				}
			} catch (e:Dynamic) {}
		}
	}
	#else

	/**
	 * Non-desktop stubs
	 */
	public function new(info:UpdateInfo) {}

	public function start():Void {}

	public function phase():String
		return 'error';

	public function percent():Float
		return 0;

	public function error():String
		return 'The in-engine updater is desktop-only.';

	public function isReady():Bool
		return false;

	public function needsElevation():Bool
		return false;

	public function popLogs():Array<String>
		return [];

	public function relaunch():Void {}

	public static function applyPendingOnBoot():Void {}

	public static function cleanupOnBoot():Void {}
	#end
}
