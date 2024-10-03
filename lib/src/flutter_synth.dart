// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of flutter_synth;

class FlutterSynth {
  ///////////////////
  //  Internal
  //

  static bool _initialized = false;

  /// native platform channel
  static final MethodChannel _methodChannel = const MethodChannel('flutter_synth/methods');

  /// a broadcast stream version of the MethodChannel
  // ignore: close_sinks
  static final StreamController<MethodCall> _methodStream = StreamController.broadcast();
  static StreamController<MethodCall> get methodStream => _methodStream; //SNTX expose methodStream

  /// FlutterSynth log level
  static LogLevel _logLevel = LogLevel.debug;
  static bool _logColor = true;

  ////////////////////
  //  Public
  //

  static LogLevel get logLevel => _logLevel;

  /// Set configurable options
  ///   - [showPowerAlert] Whether to show the power alert (iOS & MacOS only). i.e. CBCentralManagerOptionShowPowerAlertKey
  ///       To set this option you must call this method before any other method in this package.
  ///       See: https://developer.apple.com/documentation/corebluetooth/cbcentralmanageroptionshowpoweralertkey
  ///       This option has no effect on Android.
  static Future<void> setOptions({
    bool showPowerAlert = true,
  }) async {
    await _invokeMethod('setOptions', {"show_power_alert": showPowerAlert});
  }

  /// Sets the internal FlutterBlue log level
  static Future<void> setLogLevel(LogLevel level, {color = true}) async {
    _logLevel = level;
    _logColor = color;
    await _invokeMethod('setLogLevel', level.index);
  }

  static Future<dynamic> _initFlutterSynth() async {
    if (_initialized) {
      return;
    }

    _initialized = true;

    // set platform method handler
    _methodChannel.setMethodCallHandler(_methodCallHandler);

    // flutter restart - wait for all devices to disconnect
    if ((await _methodChannel.invokeMethod('flutterRestart')) != 0) {
      await Future.delayed(Duration(milliseconds: 50));
      while ((await _methodChannel.invokeMethod('connectedCount')) != 0) {
        await Future.delayed(Duration(milliseconds: 50));
      }
    }
  }

  static Future<dynamic> _methodCallHandler(MethodCall call) async {
    // log result
    if (logLevel == LogLevel.verbose) {
      String func = '[[ ${call.method} ]]';
      String result = call.arguments.toString();
      func = _logColor ? _black(func) : func;
      result = _logColor ? _brown(result) : result;
      print("[FSP] $func result: $result");
    }

    _methodStream.add(call);
  }

  /// invoke a platform method
  static Future<dynamic> _invokeMethod(
    String method, [
    dynamic arguments,
  ]) async {
    // return value
    dynamic out;

    // only allow 1 invocation at a time (guarantees that hot restart finishes)
    _Mutex mtx = _MutexFactory.getMutexForKey("invokeMethod");
    await mtx.take();

    try {
      // initialize
      if (method != "setOptions") {
        _initFlutterSynth();
      }

      // log args
      if (logLevel == LogLevel.verbose) {
        String func = '<$method>';
        String args = arguments.toString();
        func = _logColor ? _black(func) : func;
        args = _logColor ? _magenta(args) : args;
        print("[FBP] $func args: $args");
      }

      // invoke
      out = await _methodChannel.invokeMethod(method, arguments);

      // log result
      if (logLevel == LogLevel.verbose) {
        String func = '<$method>';
        String result = out.toString();
        func = _logColor ? _black(func) : func;
        result = _logColor ? _brown(result) : result;
        print("[FBP] $func result: $result");
      }
    } finally {
      mtx.give();
    }

    return out;
  }

  @Deprecated('No longer needed, remove this from your code')
  static void get instance => null;
}

/// Log levels for FlutterBlue
enum LogLevel {
  none, //0
  error, // 1
  warning, // 2
  info, // 3
  debug, // 4
  verbose, //5
}

enum ErrorPlatform {
  fbp,
  android,
  apple,
}

final ErrorPlatform _nativeError = (() {
  if (Platform.isAndroid) {
    return ErrorPlatform.android;
  } else {
    return ErrorPlatform.apple;
  }
})();

class FlutterSynthException implements Exception {
  /// Which platform did the error occur on?
  final ErrorPlatform platform;

  /// Which function failed?
  final String function;

  /// note: depends on platform
  final int? code;

  /// note: depends on platform
  final String? description;

  FlutterSynthException(this.platform, this.function, this.code, this.description);

  @override
  String toString() {
    String sPlatform = platform.toString().split('.').last;
    return 'FlutterBluePlusException | $function | $sPlatform-code: $code | $description';
  }

  @Deprecated('Use function instead')
  String get errorName => function;

  @Deprecated('Use code instead')
  int? get errorCode => code;

  @Deprecated('Use description instead')
  String? get errorString => description;
}
