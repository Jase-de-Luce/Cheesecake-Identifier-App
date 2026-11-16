import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

late List<CameraDescription> _cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _cameras = await availableCameras();
  runApp(const CheesecakeAsciiApp());
}

class CheesecakeAsciiApp extends StatelessWidget {
  const CheesecakeAsciiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        textTheme: const TextTheme(
          bodyMedium: TextStyle(fontFamily: 'monospace'),
        ),
      ),
      home: const StartScreen(),
    );
  }
}

class SinglePlayGif extends StatefulWidget {
  final String assetPath;
  final double? width;
  final double? height;
  final BoxFit fit;
  final bool playHalf;

  const SinglePlayGif({
    super.key,
    required this.assetPath,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.playHalf = false,
  });

  @override
  State<SinglePlayGif> createState() => _SinglePlayGifState();
}

class _SinglePlayGifState extends State<SinglePlayGif> {
  ui.Image? _currentFrame;

  @override
  void initState() {
    super.initState();
    _playOnce();
  }

  Future<void> _playOnce() async {
    final ByteData data = await rootBundle.load(widget.assetPath);
    final ui.Codec codec =
        await ui.instantiateImageCodec(data.buffer.asUint8List());
    final int frameCount =
        widget.playHalf ? (codec.frameCount / 2).ceil() : codec.frameCount;

    for (int i = 0; i < frameCount; i++) {
      if (!mounted) return;
      final ui.FrameInfo frameInfo = await codec.getNextFrame();

      setState(() {
        _currentFrame = frameInfo.image;
      });

      if (i < frameCount - 1) {
        await Future.delayed(frameInfo.duration);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_currentFrame == null) {
      return SizedBox(width: widget.width, height: widget.height);
    }

    return RawImage(
      image: _currentFrame,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      filterQuality: FilterQuality.none,
    );
  }
}

class StartScreen extends StatefulWidget {
  const StartScreen({super.key});

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  void _onStartTap() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const CameraScannerScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: SizedBox(
          width: 320,
          height: 450,
          child: Stack(
            alignment: Alignment.center,
            children: [
              const SinglePlayGif(
                assetPath: 'assets/start.gif',
                width: 320,
                height: 450,
                playHalf: false,
              ),
              Positioned(
                bottom: 55,
                left: 65,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _onStartTap,
                  child: const SizedBox(
                    width: 150,
                    height: 200,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CameraScannerScreen extends StatefulWidget {
  const CameraScannerScreen({super.key});

  @override
  State<CameraScannerScreen> createState() => _CameraScannerScreenState();
}

class _CameraScannerScreenState extends State<CameraScannerScreen> {
  CameraController? _cameraController;
  Interpreter? _interpreter;

  bool _isCameraReady = false;
  bool _isAnalyzing = false;
  bool _animatePanel = false;
  bool _isGlitching = false;

  File? _capturedImage;
  bool? _isCheesecake;
  double _confidence = 0.0;

  int _animTick = 0;
  Timer? _animTimer;
  final Random _random = Random();

  final List<String> _crosshairFrames = [
    '''
+-------+

|  ( )  |
+-------+''',
    '''
x-------x

|  (+)  |
x-------x''',
    '''
*-------*

|  [o]  |
*-------*''',
    '''
#-------#

|  <*>  |
#-------#''',
  ];

  @override
  void initState() {
    super.initState();
    _initModel();
    _initCamera();
    _animTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) {
        setState(() => _animTick++);
      }
    });
  }

  Future<void> _initModel() async {
    try {
      _interpreter =
          await Interpreter.fromAsset('assets/cheesecake_model.tflite');
    } catch (e) {
      debugPrint('Model load error: $e');
    }
  }

  Future<void> _initCamera() async {
    if (_cameras.isEmpty) return;
    _cameraController = CameraController(
      _cameras.first,
      ResolutionPreset.low,
      enableAudio: false,
    );

    await _cameraController!.initialize();
    if (!mounted) return;
    setState(() => _isCameraReady = true);
  }

  Future<void> _takeAndAnalyzePicture() async {
    if (!_isCameraReady || _isAnalyzing || _cameraController == null) return;

    setState(() => _isAnalyzing = true);

    try {
      final XFile rawFile = await _cameraController!.takePicture();
      final File imageFile = File(rawFile.path);
      final Uint8List bytes = await imageFile.readAsBytes();

      img.Image? decoded = img.decodeImage(bytes);
      if (decoded != null && _interpreter != null) {
        img.Image resized = img.copyResize(decoded, width: 128, height: 128);

        var input = List.generate(
          1,
          (_) => List.generate(
            128,
            (y) => List.generate(
              128,
              (x) {
                final pixel = resized.getPixel(x, y);
                return [
                  pixel.r.toDouble(),
                  pixel.g.toDouble(),
                  pixel.b.toDouble(),
                ];
              },
            ),
          ),
        );

        var output = List.generate(1, (_) => List.filled(1, 0.0));
        _interpreter!.run(input, output);

        double score = output[0][0];
        bool detected = score < 0.5;
        double conf = detected ? (1.0 - score) * 100 : score * 100;

        setState(() {
          _capturedImage = imageFile;
          _isCheesecake = detected;
          _confidence = conf;
          _isAnalyzing = false;
          _animatePanel = false;
        });

        Future.delayed(const Duration(milliseconds: 50), () {
          if (mounted) {
            setState(() => _animatePanel = true);
          }
        });
      }
    } catch (e) {
      debugPrint('Inference error: $e');
      setState(() => _isAnalyzing = false);
    }
  }

  Future<void> _triggerGlitchAndReturn() async {
    if (_isGlitching) return;
    setState(() => _isGlitching = true);

    await Future.delayed(const Duration(milliseconds: 650));

    if (!mounted) return;
    setState(() {
      _isGlitching = false;
      _capturedImage = null;
      _isCheesecake = null;
      _animatePanel = false;
    });
  }

  @override
  void dispose() {
    _animTimer?.cancel();
    _cameraController?.dispose();
    _interpreter?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;

    if (_capturedImage != null && _isCheesecake != null) {
      return GestureDetector(
        onTap: _triggerGlitchAndReturn,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 450),
                curve: Curves.easeOutCubic,
                top: _isGlitching ? (_random.nextDouble() - 0.5) * 30 : 0,
                left: _isGlitching ? (_random.nextDouble() - 0.5) * 40 : 0,
                right: 0,
                height: _animatePanel ? screenHeight * 0.33 : screenHeight,
                child: Image.file(
                  _capturedImage!,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.none,
                ),
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 450),
                curve: Curves.easeOutCubic,
                left: 0,
                right: 0,
                bottom: _animatePanel ? 0 : -(screenHeight * 0.67),
                height: screenHeight * 0.67,
                child: Container(
                  decoration: const BoxDecoration(
                    color: Colors.black,
                    border: Border(
                      top: BorderSide(color: Colors.white24, width: 2),
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SinglePlayGif(
                        assetPath: _isCheesecake!
                            ? 'assets/acheesecake.gif'
                            : 'assets/notacheesecake.gif',
                        width: 300,
                        height: 300,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _isCheesecake!
                            ? 'CHEESECAKE DISCOVERED!\n[ACCURACY: ${_confidence.toStringAsFixed(1)}%]'
                            : 'THIS IS NOT A CHEESECAKE!\n[ACCURACY: ${_confidence.toStringAsFixed(1)}%]',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'monospace',
fontSize: 18,
fontWeight: FontWeight.bold,
color: _isCheesecake!
? const Color(0xFFBFFF00)
: const Color(0xFFFF2E2E),
),
),
const SizedBox(height: 8),
const Text(
'[ TAP THE SCREEN TO RESET ]',
style: TextStyle(
fontFamily: 'monospace',
fontSize: 12,
color: Colors.white54,
),
),
],
),
),
),
if (_isGlitching)
Container(
color: const Color(0xFFBFFF00).withValues(alpha: 0.85),
child: Center(
child: _buildGlitchNoise(),
),
),
],
),
),
);
}
return Scaffold(
backgroundColor: Colors.black,
body: Stack(
fit: StackFit.expand,
children: [
if (_isCameraReady && _cameraController != null)
CameraPreview(_cameraController!)
else
const Center(
child: Text(
'LOADING CAMERA 240p...',
style: TextStyle(color: Colors.white, fontFamily: 'monospace'),
),
),
Center(
child: Text(
_isAnalyzing
? '[ ANALYZING... ]\n[ ||||.... ]'
: _crosshairFrames[_animTick % _crosshairFrames.length],
textAlign: TextAlign.center,
style: TextStyle(
fontFamily: 'monospace',
fontSize: 22,
fontWeight: FontWeight.bold,
color: Colors.white.withValues(alpha: 0.55),
),
),
),
Positioned(
bottom: 40,
left: 0,
right: 0,
child: Center(
child: GestureDetector(
onTap: _takeAndAnalyzePicture,
child: Container(
color: Colors.black.withValues(alpha: 0.5),
padding: const EdgeInsets.all(6),
child: const Text(
'''
+-------+
| [ O ] |
| SHOOT |
+-------+''',
textAlign: TextAlign.center,
style: TextStyle(
fontFamily: 'monospace',
fontSize: 18,
fontWeight: FontWeight.bold,
color: Color(0xFFBFFF00),
height: 1.1,
),
),
),
),
),
),
],
),
);
}
Widget _buildGlitchNoise() {
const chars = '@#%&*+=-:/?01';
final buffer = StringBuffer();
for (int i = 0; i < 16; i++) {
for (int j = 0; j < 26; j++) {
buffer.write(chars[_random.nextInt(chars.length)]);
}
buffer.writeln();
}
return Text(
buffer.toString(),
style: const TextStyle(
fontFamily: 'monospace',
fontSize: 16,
color: Colors.black,
height: 1.0,
),
);
}
}