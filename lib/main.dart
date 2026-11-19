import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const TubeFlowApp());
}

class TubeFlowApp extends StatelessWidget {
  const TubeFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'TubeFlow',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF08090D),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E58A),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class DownloadedItem {
  final String name;
  final String sizeLabel;
  final String path;
  final bool isAudio;

  DownloadedItem({
    required this.name,
    required this.sizeLabel,
    required this.path,
    required this.isAudio,
  });
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController urlController = TextEditingController();

  bool analyzing = false;
  bool downloading = false;

  double progress = 0;

  String status = 'Paste a YouTube link to get started.';

  String? analyzedUrl;
  String? videoTitle;
  String? fileSizePreview;

  String selectedFormat = 'MP4';

  // null means best available quality.
  int? selectedResolution;

  List<int> availableResolutions = [];

  final List<String> formats = ['MP4', 'MP3'];

  final List<DownloadedItem> recentDownloads = [];

  static const green = Color(0xFF00E58A);
  static const card = Color(0xFF15151D);
  static const muted = Color(0xFF8990A5);

  @override
  void initState() {
    super.initState();
    _loadExistingDownloads();
  }

  // --------------------------------------------------
  // SAVE DIRECTORY
  // --------------------------------------------------

  Future<Directory> _getSaveDirectory() async {
    Directory? baseDir;

    if (Platform.isAndroid) {
      baseDir = await getExternalStorageDirectory();
    } else if (Platform.isIOS) {
      baseDir = await getApplicationDocumentsDirectory();
    } else {
      baseDir = await getDownloadsDirectory();
    }

    baseDir ??= await getApplicationDocumentsDirectory();

    final folder = Directory('${baseDir.path}/TubeFlow');

    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }

    return folder;
  }

  // --------------------------------------------------
  // LOAD DOWNLOADS
  // --------------------------------------------------

  Future<void> _loadExistingDownloads() async {
    try {
      final folder = await _getSaveDirectory();

      final entities = folder
          .listSync()
          .whereType<File>()
          .where((file) => !file.path.endsWith('.part'))
          .toList()
        ..sort(
          (a, b) => b.lastModifiedSync().compareTo(
                a.lastModifiedSync(),
              ),
        );

      final loaded = entities.map((file) {
        final name = file.uri.pathSegments.last;

        final isAudio = [
          '.mp3',
          '.wav',
          '.ogg',
          '.m4a',
        ].any((ext) => name.toLowerCase().endsWith(ext));

        return DownloadedItem(
          name: name,
          sizeLabel: _formatBytes(file.lengthSync()),
          path: file.path,
          isAudio: isAudio,
        );
      }).toList();

      if (!mounted) return;

      setState(() {
        recentDownloads
          ..clear()
          ..addAll(loaded);
      });
    } catch (e) {
      debugPrint('Could not load downloads: $e');
    }
  }

  // --------------------------------------------------
  // FORMAT FILE SIZE
  // --------------------------------------------------

  String _formatBytes(int bytes) {
    if (bytes <= 0) return 'Unknown size';

    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];

    var i = 0;
    double size = bytes.toDouble();

    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }

    return '${size.toStringAsFixed(1)} ${suffixes[i]}';
  }

  // --------------------------------------------------
  // PASTE URL
  // --------------------------------------------------

  Future<void> pasteUrl() async {
    final data = await Clipboard.getData(
      Clipboard.kTextPlain,
    );

    if (data?.text == null || data!.text!.trim().isEmpty) {
      return;
    }

    setState(() {
      urlController.text = data.text!.trim();

      analyzedUrl = null;
      videoTitle = null;
      fileSizePreview = null;
      availableResolutions.clear();
      selectedResolution = null;

      status = 'Link pasted. Ready to analyze.';
    });
  }

  // --------------------------------------------------
  // ANALYZE YOUTUBE VIDEO
  // --------------------------------------------------

  Future<void> analyzeLink() async {
    final input = urlController.text.trim();
    final uri = Uri.tryParse(input);

    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      setState(() {
        status = 'Please enter a valid URL.';
        analyzedUrl = null;
        videoTitle = null;
      });

      return;
    }

    setState(() {
      analyzing = true;

      status = 'Analyzing with yt-dlp...';

      analyzedUrl = null;
      videoTitle = null;
      fileSizePreview = null;

      availableResolutions.clear();
      selectedResolution = null;
    });

    try {
      final result = await Process.run(
        'yt-dlp',
        [
          '--dump-single-json',
          '--no-warnings',
          '--no-playlist',
          '--no-download',
          input,
        ],
      );

      if (result.exitCode != 0) {
        final error = (result.stderr as String).trim();

        throw Exception(
          error.isEmpty
              ? 'Could not retrieve video information.'
              : error,
        );
      }

      final info = jsonDecode(
        result.stdout as String,
      ) as Map<String, dynamic>;

      final title = (info['title'] ?? 'YouTube video').toString();

      final size = (
        info['filesize'] ??
        info['filesize_approx']
      ) as num?;

      final duration = info['duration'] as num?;

      // Retrieve available video resolutions.

      final rawFormats = info['formats'] as List<dynamic>? ?? [];

      final heights = <int>{};

      for (final item in rawFormats) {
        if (item is! Map) continue;

        final height = item['height'];
        final videoCodec = item['vcodec'];

        if (height is num &&
            videoCodec != null &&
            videoCodec.toString() != 'none') {
          if (height > 0) {
            heights.add(height.toInt());
          }
        }
      }

      final sortedHeights = heights.toList()
        ..sort((a, b) => b.compareTo(a));

      if (!mounted) return;

      setState(() {
        analyzedUrl = input;
        videoTitle = title;

        fileSizePreview = size != null && size > 0
            ? _formatBytes(size.toInt())
            : null;

        availableResolutions = sortedHeights;

        // Best available is selected by default.
        selectedResolution = null;

        String durationText = '';

        if (duration != null) {
          final seconds = duration.toInt();

          final minutes = seconds ~/ 60;
          final remainingSeconds = seconds % 60;

          durationText =
              ' • $minutes:${remainingSeconds.toString().padLeft(2, '0')}';
        }

        status = 'Video found$durationText. Ready to download.';
      });
    } on ProcessException {
      if (!mounted) return;

      setState(() {
        status =
            'yt-dlp is not installed or is not available in PATH.';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        status = 'Could not analyze video: $e';

        analyzedUrl = null;
        videoTitle = null;
        fileSizePreview = null;
      });
    } finally {
      if (mounted) {
        setState(() {
          analyzing = false;
        });
      }
    }
  }

  // --------------------------------------------------
  // DOWNLOAD VIDEO OR AUDIO
  // --------------------------------------------------

  Future<void> downloadFile() async {
    if (analyzedUrl == null) return;

    setState(() {
      downloading = true;
      progress = 0;
      status = 'Starting download...';
    });

    StreamSubscription<String>? stderrSubscription;

    try {
      final folder = await _getSaveDirectory();

      final args = <String>[
        '--newline',
        '--no-colors',
        '--no-playlist',
        '--progress',
        '--output',
        '${folder.path}/%(title).180B [%(id)s].%(ext)s',
      ];

      // MP3 MODE

      if (selectedFormat == 'MP3') {
        args.addAll([
          '--extract-audio',
          '--audio-format',
          'mp3',
          '--audio-quality',
          '0',
        ]);
      }

      // MP4 MODE

      else {
        String formatSelector;

        if (selectedResolution == null) {
          formatSelector = 'bestvideo*+bestaudio/best';
        } else {
          final height = selectedResolution;

          formatSelector =
              'bestvideo[height<=$height]+bestaudio/'
              'best[height<=$height]';
        }

        args.addAll([
          '--format',
          formatSelector,
          '--merge-output-format',
          'mp4',
        ]);
      }

      args.add(analyzedUrl!);

      final process = await Process.start(
        'yt-dlp',
        args,
      );

      stderrSubscription = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final match = RegExp(
          r'(\d+(?:\.\d+)?)%',
        ).firstMatch(line);

        if (match != null && mounted) {
          final percent =
              double.tryParse(match.group(1)!) ?? 0;

          setState(() {
            progress = (percent / 100).clamp(0.0, 1.0);

            status =
                'Downloading ${percent.toStringAsFixed(1)}%';
          });
        }

        if (line.contains('ERROR:') && mounted) {
          setState(() {
            status = line.replaceFirst(
              'ERROR:',
              '',
            ).trim();
          });
        }
      });

      final stdoutFuture = process.stdout
          .transform(utf8.decoder)
          .join();

      final exitCode = await process.exitCode;

      final stdoutText = await stdoutFuture;

      await stderrSubscription.cancel();
      stderrSubscription = null;

      if (exitCode != 0) {
        throw Exception(
          'yt-dlp exited with code $exitCode. $stdoutText',
        );
      }

      await _loadExistingDownloads();

      if (!mounted) return;

      setState(() {
        progress = 1;

        status =
            'Download complete! Saved in Downloads/TubeFlow.';
      });
    } on ProcessException {
      if (!mounted) return;

      setState(() {
        status =
            'yt-dlp could not be found. Install it first.';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        status = 'Download failed: $e';
      });
    } finally {
      await stderrSubscription?.cancel();

      if (mounted) {
        setState(() {
          downloading = false;
        });
      }
    }
  }

  // --------------------------------------------------
  // DELETE DOWNLOAD
  // --------------------------------------------------

  Future<void> _deleteFile(DownloadedItem item) async {
    try {
      final file = File(item.path);

      if (await file.exists()) {
        await file.delete();
      }

      await _loadExistingDownloads();
    } catch (e) {
      debugPrint('Delete failed: $e');
    }
  }

  @override
  void dispose() {
    urlController.dispose();
    super.dispose();
  }

  // --------------------------------------------------
  // UI
  // --------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.2, -0.9),
            radius: 1.1,
            colors: [
              Color(0xFF0E2918),
              Color(0xFF08090D),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: 650,
              ),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  // HEADER

                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: green,
                          borderRadius: BorderRadius.circular(13),
                          boxShadow: [
                            BoxShadow(
                              color: green.withOpacity(0.3),
                              blurRadius: 14,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.download_rounded,
                          color: Colors.black,
                        ),
                      ),

                      const SizedBox(width: 12),

                      const Text(
                        'TubeFlow',
                        style: TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.bold,
                        ),
                      ),

                      const Spacer(),

                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: card,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: const Color(0xFF1F222A),
                          ),
                        ),
                        child: Text(
                          '${recentDownloads.length} saved',
                          style: const TextStyle(
                            color: green,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 36),

                  // MAIN TITLE

                  const Text(
                    'Download media.',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -1.1,
                    ),
                  ),

                  const SizedBox(height: 8),

                  const Text(
                    'Paste a YouTube URL and choose your quality.',
                    style: TextStyle(
                      color: muted,
                      fontSize: 14,
                    ),
                  ),

                  const SizedBox(height: 26),

                  // URL INPUT CARD

                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: card,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: green.withOpacity(0.25),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(
                              Icons.link,
                              color: green,
                              size: 18,
                            ),
                            SizedBox(width: 8),
                            Text(
                              'YOUTUBE URL',
                              style: TextStyle(
                                color: muted,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.4,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 14),

                        TextField(
                          controller: urlController,
                          keyboardType: TextInputType.url,
                          style: const TextStyle(
                            fontSize: 14,
                          ),
                          decoration: InputDecoration(
                            hintText:
                                'https://www.youtube.com/watch?v=...',
                            hintStyle: const TextStyle(
                              color: Color(0xFF4F5565),
                            ),
                            filled: true,
                            fillColor: const Color(0xFF0B0C12),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.all(16),
                            suffixIcon: IconButton(
                              tooltip: 'Paste',
                              onPressed: pasteUrl,
                              icon: const Icon(
                                Icons.content_paste_rounded,
                                color: green,
                              ),
                            ),
                          ),
                          onChanged: (_) {
                            setState(() {
                              analyzedUrl = null;
                              videoTitle = null;
                              fileSizePreview = null;

                              availableResolutions.clear();
                              selectedResolution = null;

                              status = 'Link changed. Analyze it again.';
                            });
                          },
                        ),

                        const SizedBox(height: 14),

                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: FilledButton.icon(
                            onPressed: analyzing || downloading
                                ? null
                                : analyzeLink,
                            style: FilledButton.styleFrom(
                              backgroundColor: green,
                              foregroundColor: Colors.black,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            icon: analyzing
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.black,
                                    ),
                                  )
                                : const Icon(
                                    Icons.search_rounded,
                                  ),
                            label: Text(
                              analyzing
                                  ? 'Analyzing...'
                                  : 'Analyze video',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 14),

                        Text(
                          status,
                          style: const TextStyle(
                            color: muted,
                            fontSize: 13,
                          ),
                        ),

                        // VIDEO INFORMATION

                        if (videoTitle != null) ...[
                          const SizedBox(height: 12),

                          Text(
                            videoTitle!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],

                        // FORMAT SELECTION

                        if (analyzedUrl != null) ...[
                          const SizedBox(height: 22),

                          const Text(
                            'FORMAT',
                            style: TextStyle(
                              color: muted,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.4,
                            ),
                          ),

                          const SizedBox(height: 10),

                          Wrap(
                            spacing: 10,
                            children: formats.map((format) {
                              final selected =
                                  selectedFormat == format;

                              return ChoiceChip(
                                label: Text(format),
                                selected: selected,
                                onSelected: downloading
                                    ? null
                                    : (_) {
                                        setState(() {
                                          selectedFormat = format;
                                        });
                                      },
                                selectedColor: green,
                                backgroundColor: card,
                                labelStyle: TextStyle(
                                  color: selected
                                      ? Colors.black
                                      : green,
                                  fontWeight: FontWeight.bold,
                                ),
                                side: const BorderSide(
                                  color: Color(0xFF1F222A),
                                ),
                              );
                            }).toList(),
                          ),

                          // RESOLUTION SELECTION

                          if (selectedFormat == 'MP4') ...[
                            const SizedBox(height: 20),

                            const Text(
                              'VIDEO RESOLUTION',
                              style: TextStyle(
                                color: muted,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.4,
                              ),
                            ),

                            const SizedBox(height: 10),

                            DropdownButtonFormField<int>(
                              value: selectedResolution ?? 0,
                              isExpanded: true,
                              decoration: InputDecoration(
                                filled: true,
                                fillColor: const Color(0xFF0B0C12),
                                contentPadding:
                                    const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 14,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius:
                                      BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                              dropdownColor: card,
                              items: [
                                const DropdownMenuItem<int>(
                                  value: 0,
                                  child: Text('Best available'),
                                ),

                                ...availableResolutions.map(
                                  (height) {
                                    return DropdownMenuItem<int>(
                                      value: height,
                                      child: Text('${height}p'),
                                    );
                                  },
                                ),
                              ],
                              onChanged: downloading
                                  ? null
                                  : (value) {
                                      setState(() {
                                        selectedResolution =
                                            value == null || value == 0
                                                ? null
                                                : value;
                                      });
                                    },
                            ),

                            const SizedBox(height: 8),

                            Text(
                              '${availableResolutions.length} resolutions detected',
                              style: const TextStyle(
                                color: muted,
                                fontSize: 11,
                              ),
                            ),
                          ],

                          // DOWNLOAD BUTTON

                          const SizedBox(height: 20),

                          SizedBox(
                            width: double.infinity,
                            height: 52,
                            child: FilledButton.icon(
                              onPressed: downloading
                                  ? null
                                  : downloadFile,
                              icon: const Icon(
                                Icons.download_rounded,
                              ),
                              label: Text(
                                fileSizePreview != null
                                    ? 'Download $selectedFormat'
                                    : 'Download $selectedFormat',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                              style: FilledButton.styleFrom(
                                backgroundColor:
                                    const Color(0xFF1E242B),
                                foregroundColor: green,
                                shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        ],

                        // PROGRESS BAR

                        if (downloading) ...[
                          const SizedBox(height: 18),

                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: LinearProgressIndicator(
                              value: progress > 0
                                  ? progress
                                  : null,
                              minHeight: 6,
                              backgroundColor: Colors.black,
                              color: green,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 28),

                  // RECENT DOWNLOADS

                  const Text(
                    'RECENT DOWNLOADS',
                    style: TextStyle(
                      color: muted,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),

                  const SizedBox(height: 12),

                  if (recentDownloads.isEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: 32,
                      ),
                      decoration: BoxDecoration(
                        color: card,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: const Color(0xFF1F222A),
                        ),
                      ),
                      child: const Column(
                        children: [
                          Icon(
                            Icons.folder_open_rounded,
                            color: green,
                            size: 30,
                          ),
                          SizedBox(height: 10),
                          Text(
                            'No downloads yet',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Your downloads will appear here',
                            style: TextStyle(
                              color: muted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    ...recentDownloads.map((item) {
                      return Container(
                        margin: const EdgeInsets.only(
                          bottom: 10,
                        ),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: card,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: const Color(0xFF1F222A),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: item.isAudio
                                    ? const Color(0xFF2B161A)
                                    : const Color(0xFF11291D),
                                borderRadius:
                                    BorderRadius.circular(10),
                              ),
                              child: Icon(
                                item.isAudio
                                    ? Icons.music_note_rounded
                                    : Icons.play_arrow_rounded,
                                color: item.isAudio
                                    ? const Color(0xFFFF5252)
                                    : green,
                                size: 20,
                              ),
                            ),

                            const SizedBox(width: 12),

                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                    ),
                                  ),

                                  const SizedBox(height: 3),

                                  Text(
                                    item.sizeLabel,
                                    style: const TextStyle(
                                      color: muted,
                                      fontSize: 12,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            IconButton(
                              tooltip: 'Delete',
                              onPressed: () => _deleteFile(item),
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                color: muted,
                                size: 20,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),

                  const SizedBox(height: 24),

                  // NOTICE

                  Container(
                    padding: const EdgeInsets.all(15),
                    decoration: BoxDecoration(
                      color: card,
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline,
                          color: muted,
                          size: 18,
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Only download media you own or have permission to save. '
                            'Some websites do not allow third-party downloads.',
                            style: TextStyle(
                              color: muted,
                              fontSize: 12,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}