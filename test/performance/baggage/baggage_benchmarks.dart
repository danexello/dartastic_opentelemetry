// Licensed under the Apache License, Version 2.0
// Copyright 2025, Michael Bushe, All rights reserved.

import 'package:dartastic_opentelemetry/src/otel.dart';
import 'package:dartastic_opentelemetry/src/trace/export/baggage_span_processor.dart';
import 'package:dartastic_opentelemetry/src/trace/export/simple_span_processor.dart';
import 'package:dartastic_opentelemetry/src/trace/export/span_exporter.dart';
import 'package:dartastic_opentelemetry/src/trace/span.dart';
import 'package:dartastic_opentelemetry/src/trace/tracer.dart';
import 'package:dartastic_opentelemetry/src/trace/tracer_provider.dart';
import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';

import '../benchmark_runner.dart';

/// Measures the overhead of baggage creation and manipulation
class BaggageOperationsBenchmark extends DartasticBenchmark {
  static const int numOperations = 1000;
  final int numEntries;

  late Baggage _testBaggage;

  BaggageOperationsBenchmark({this.numEntries = 10})
      : super('Baggage Operations ($numEntries entries)');

  @override
  void setup() {
    _testBaggage = OTel.baggage();
    for (var i = 0; i < numEntries; i++) {
      _testBaggage = _testBaggage.copyWith(
        'key.$i',
        'value.$i',
        'metadata.$i',
      );
    }
  }

  @override
  void run() {
    for (var i = 0; i < numOperations; i++) {
      _testBaggage = _testBaggage.copyWith('test.key', 'test.value');
      _testBaggage.getEntry('key.1');
      _testBaggage = _testBaggage.copyWithout('test.key');
      _testBaggage.getAllEntries();
    }
  }

  @override
  void printConfig() {
    print('  Number of entries: $numEntries');
    print('  Operations per run: $numOperations');
  }
}

/// Measures the impact of baggage size on cross-isolate performance
class BaggageIsolateBenchmark extends DartasticBenchmark {
  static const int numIterations = 100;
  final int numEntries;
  late Baggage _baggage;

  BaggageIsolateBenchmark({this.numEntries = 10})
      : super('Baggage Isolate Crossing ($numEntries entries)');

  @override
  void setup() {
    _baggage = OTel.baggage();
    for (var i = 0; i < numEntries; i++) {
      _baggage = _baggage.copyWith(
        'key.$i',
        'value.$i',
        'metadata.$i',
      );
    }
  }

  @override
  void run() async {
    for (var i = 0; i < numIterations; i++) {
      await Context.current.withBaggage(_baggage).runIsolate(() async {
        final propagated = Context.currentWithBaggage().baggage;
        return propagated?.getAllEntries().length ?? 0;
      });
    }
  }

  @override
  void printConfig() {
    print('  Number of baggage entries: $numEntries');
    print('  Number of isolate crossings: $numIterations');
  }
}

/// Measures memory impact of baggage with different cardinalities
class BaggageMemoryBenchmark extends DartasticBenchmark {
  final int numUniqueKeys;
  final int numValuesPerKey;
  late List<Baggage> _baggages;

  BaggageMemoryBenchmark({
    this.numUniqueKeys = 100,
    this.numValuesPerKey = 1000,
  }) : super('Baggage Memory ($numUniqueKeys keys × $numValuesPerKey values)');

  @override
  void setup() {
    _baggages = [];
    for (var i = 0; i < numValuesPerKey; i++) {
      var baggage = OTel.baggage();
      for (var j = 0; j < numUniqueKeys; j++) {
        baggage = baggage.copyWith('key.$j', 'value.$i.$j');
      }
      _baggages.add(baggage);
    }
  }

  @override
  void run() {
    for (var baggage in _baggages.take(100)) {
      baggage.getAllEntries();
    }
  }

  @override
  void printConfig() {
    print('  Number of unique keys: $numUniqueKeys');
    print('  Values per key: $numValuesPerKey');
    // Setup hasn't run yet when printConfig is called
    print('  Total baggage instances (planned): $numValuesPerKey');
  }

  @override
  void printExtraStats() {
    final snapshot = MemorySnapshot();
    print('  Current memory usage:');
    print('    RSS: ${snapshot.rss ~/ 1024} KB');
    print('    Heap: ${snapshot.heap ~/ 1024} KB');
    print(
        '  Average memory per entry: ${(snapshot.heap / (numUniqueKeys * numValuesPerKey)).toStringAsFixed(2)} bytes');
  }
}

/// No-op exporter that discards spans without I/O overhead
class NoOpSpanExporter implements SpanExporter {
  @override
  Future<void> export(List<Span> spans) async {
    // Discard spans - no-op for benchmarking
  }

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

/// Measures span creation overhead with BaggageSpanProcessor
class BaggageSpanProcessorOverheadBenchmark extends DartasticBenchmark {
  static const int numSpans = 1000;
  final int numBaggageEntries;
  final bool withProcessor;

  late TracerProvider _tracerProvider;
  late Tracer _tracer;
  late Baggage _baggage;

  BaggageSpanProcessorOverheadBenchmark({
    required this.numBaggageEntries,
    required this.withProcessor,
  }) : super(
            'BaggageSpanProcessor Overhead ($numBaggageEntries entries, ${withProcessor ? "with" : "without"} processor)');

  @override
  void setup() {
    _tracerProvider = OTel.tracerProvider();

    // Add BaggageSpanProcessor if testing with it
    if (withProcessor) {
      _tracerProvider.addSpanProcessor(const BaggageSpanProcessor());
    }

    _tracer = _tracerProvider.getTracer('benchmark-tracer');

    // Create baggage with specified number of entries
    _baggage = OTel.baggage();
    for (var i = 0; i < numBaggageEntries; i++) {
      _baggage = _baggage.copyWith('key.$i', 'value.$i', 'metadata.$i');
    }
  }

  @override
  void run() async {
    // Set baggage in context and create spans
    await Context.current.withBaggage(_baggage).run<void>(() async {
      for (var i = 0; i < numSpans; i++) {
        final span = _tracer.startSpan('benchmark-span');
        span.end();
      }
    });
  }

  @override
  void teardown() async {
    await _tracerProvider.forceFlush();
    await _tracerProvider.shutdown();
    await OTel.reset();
  }

  @override
  void printConfig() {
    print('  Number of baggage entries: $numBaggageEntries');
    print('  Spans created: $numSpans');
    print('  BaggageSpanProcessor: ${withProcessor ? "enabled" : "disabled"}');
  }
}

/// Measures performance scaling with different baggage sizes
class BaggageSpanProcessorScalingBenchmark extends DartasticBenchmark {
  static const int numSpans = 1000;
  final int numBaggageEntries;

  late TracerProvider _tracerProvider;
  late Tracer _tracer;
  late Baggage _baggage;

  BaggageSpanProcessorScalingBenchmark({required this.numBaggageEntries})
      : super('BaggageSpanProcessor Scaling ($numBaggageEntries entries)');

  @override
  void setup() {
    _tracerProvider = OTel.tracerProvider();
    _tracerProvider.addSpanProcessor(const BaggageSpanProcessor());

    _tracer = _tracerProvider.getTracer('benchmark-tracer');

    // Create baggage with specified number of entries
    _baggage = OTel.baggage();
    for (var i = 0; i < numBaggageEntries; i++) {
      _baggage = _baggage.copyWith('key.$i', 'value.$i', 'metadata.$i');
    }
  }

  @override
  void run() async {
    await Context.current.withBaggage(_baggage).run<void>(() async {
      for (var i = 0; i < numSpans; i++) {
        final span = _tracer.startSpan('benchmark-span');
        span.end();
      }
    });
  }

  @override
  void teardown() async {
    await _tracerProvider.forceFlush();
    await _tracerProvider.shutdown();
    await OTel.reset();
  }

  @override
  void printConfig() {
    print('  Number of baggage entries: $numBaggageEntries');
    print('  Spans created: $numSpans');
  }

  @override
  void printExtraStats() {
    final spansPerSecond = (numSpans / (measure() / 1000000)).round();
    print('  Throughput: $spansPerSecond spans/second');
  }
}

/// Measures memory impact of spans with baggage attributes
class BaggageSpanProcessorMemoryBenchmark extends DartasticBenchmark {
  static const int numSpans = 1000;
  final int numBaggageEntries;

  late TracerProvider _tracerProvider;
  late Tracer _tracer;
  late Baggage _baggage;
  late MemorySnapshot _memBefore;

  BaggageSpanProcessorMemoryBenchmark({required this.numBaggageEntries})
      : super('BaggageSpanProcessor Memory ($numBaggageEntries entries)');

  @override
  void setup() {
    _tracerProvider = OTel.tracerProvider();
    _tracerProvider.addSpanProcessor(const BaggageSpanProcessor());

    _tracer = _tracerProvider.getTracer('benchmark-tracer');

    // Create baggage with specified number of entries
    _baggage = OTel.baggage();
    for (var i = 0; i < numBaggageEntries; i++) {
      _baggage = _baggage.copyWith('key.$i', 'value.$i', 'metadata.$i');
    }

    _memBefore = MemorySnapshot();
  }

  @override
  void run() async {
    await Context.current.withBaggage(_baggage).run<void>(() async {
      for (var i = 0; i < numSpans; i++) {
        final span = _tracer.startSpan('benchmark-span');
        span.end();
      }
    });
  }

  @override
  void teardown() async {
    await _tracerProvider.forceFlush();
    await _tracerProvider.shutdown();
    await OTel.reset();
  }

  @override
  void printConfig() {
    print('  Number of baggage entries: $numBaggageEntries');
    print('  Spans created: $numSpans');
  }

  @override
  void printExtraStats() {
    final memAfter = MemorySnapshot();
    final rssDelta = (memAfter.rss - _memBefore.rss) ~/ 1024;
    final heapDelta = (memAfter.heap - _memBefore.heap) ~/ 1024;
    print('  Memory delta:');
    print('    RSS: $rssDelta KB');
    print('    Heap: $heapDelta KB');
    if (numSpans > 0 && heapDelta > 0) {
      print(
          '    Average per span: ${(heapDelta * 1024 / numSpans).toStringAsFixed(2)} bytes');
    }
  }
}

/// Run all baggage benchmarks with different configurations
Future<void> main() async {
  Future<void> runWithInit(DartasticBenchmark b) async {
    await OTel.reset();
    // Small delay to ensure previous benchmark's spans have completed
    await Future.delayed(const Duration(milliseconds: 100));
    await OTel.initialize(
      serviceName: 'benchmark-service',
      serviceVersion: '1.0.0',
      spanProcessor: SimpleSpanProcessor(NoOpSpanExporter()),
    );
    b.runAndPrint();
  }

  // Basic operations benchmarks
  await runWithInit(BaggageOperationsBenchmark(numEntries: 5));
  await runWithInit(BaggageOperationsBenchmark(numEntries: 50));
  await runWithInit(BaggageOperationsBenchmark(numEntries: 500));

  // Cross-isolate benchmarks
  await runWithInit(BaggageIsolateBenchmark(numEntries: 5));
  await runWithInit(BaggageIsolateBenchmark(numEntries: 50));

  // Memory impact benchmarks
  await runWithInit(BaggageMemoryBenchmark(
    numUniqueKeys: 10,
    numValuesPerKey: 100,
  ));
  await runWithInit(BaggageMemoryBenchmark(
    numUniqueKeys: 100,
    numValuesPerKey: 1000,
  ));

  // BaggageSpanProcessor overhead benchmarks (with vs without)
  await runWithInit(BaggageSpanProcessorOverheadBenchmark(
    numBaggageEntries: 0,
    withProcessor: false,
  ));
  await runWithInit(BaggageSpanProcessorOverheadBenchmark(
    numBaggageEntries: 0,
    withProcessor: true,
  ));
  await runWithInit(BaggageSpanProcessorOverheadBenchmark(
    numBaggageEntries: 5,
    withProcessor: false,
  ));
  await runWithInit(BaggageSpanProcessorOverheadBenchmark(
    numBaggageEntries: 5,
    withProcessor: true,
  ));
  await runWithInit(BaggageSpanProcessorOverheadBenchmark(
    numBaggageEntries: 50,
    withProcessor: false,
  ));
  await runWithInit(BaggageSpanProcessorOverheadBenchmark(
    numBaggageEntries: 50,
    withProcessor: true,
  ));
  await runWithInit(BaggageSpanProcessorOverheadBenchmark(
    numBaggageEntries: 100,
    withProcessor: false,
  ));
  await runWithInit(BaggageSpanProcessorOverheadBenchmark(
    numBaggageEntries: 100,
    withProcessor: true,
  ));

  // BaggageSpanProcessor scaling benchmarks
  await runWithInit(BaggageSpanProcessorScalingBenchmark(numBaggageEntries: 5));
  await runWithInit(
      BaggageSpanProcessorScalingBenchmark(numBaggageEntries: 25));
  await runWithInit(
      BaggageSpanProcessorScalingBenchmark(numBaggageEntries: 50));
  await runWithInit(
      BaggageSpanProcessorScalingBenchmark(numBaggageEntries: 100));

  // BaggageSpanProcessor memory benchmarks
  await runWithInit(BaggageSpanProcessorMemoryBenchmark(numBaggageEntries: 10));
  await runWithInit(BaggageSpanProcessorMemoryBenchmark(numBaggageEntries: 50));
  await runWithInit(
      BaggageSpanProcessorMemoryBenchmark(numBaggageEntries: 100));
}
