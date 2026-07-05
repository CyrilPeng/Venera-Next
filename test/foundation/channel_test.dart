import 'package:flutter_test/flutter_test.dart';
import 'package:venera_next/foundation/channel.dart';

void main() {
  test("1-1-1", () async {
    var channel = Channel<int>(1);
    await channel.push(1);
    var item = await channel.pop();
    expect(item, 1);
  });

  test("1-3-1", () async {
    var channel = Channel<int>(1);

    // producer
    () async {
      await channel.push(1);
    }();
    () async {
      await channel.push(2);
    }();
    () async {
      await channel.push(3);
    }();

    // consumer
    var results = <int>[];
    for (var i = 0; i < 3; i++) {
      var item = await channel.pop();
      if (item != null) {
        results.add(item);
      }
    }
    expect(results.length, 3);
  });

  test("2-3-1", () async {
    var channel = Channel<int>(2);

    // producer
    () async {
      await channel.push(1);
    }();
    () async {
      await channel.push(2);
    }();
    () async {
      await channel.push(3);
    }();

    // consumer
    var results = <int>[];
    for (var i = 0; i < 3; i++) {
      var item = await channel.pop();
      if (item != null) {
        results.add(item);
      }
    }
    expect(results.length, 3);
  });

  test("1-1-3", () async {
    var channel = Channel<int>(1);

    // producer
    () async {
      print("push 1");
      await channel.push(1);
      print("push 2");
      await channel.push(2);
      print("push 3");
      await channel.push(3);
      print("push done");
      channel.close();
    }();

    // consumer
    var consumers = <Future>[];
    var results = <int>[];
    for (var i = 0; i < 3; i++) {
      consumers.add(() async {
        while (true) {
          var item = await channel.pop();
          if (item == null) {
            break;
          }
          print("pop $item");
          results.add(item);
        }
      }());
    }

    await Future.wait(consumers);
    expect(results.length, 3);
  });

  test("close", () async {
    var channel = Channel<int>(2);

    // producer
    () async {
      await channel.push(1);
      await channel.push(2);
      await channel.push(3);
      channel.close();
    }();

    // consumer
    await channel.pop();
    await channel.pop();
    await channel.pop();
    var item4 = await channel.pop();
    expect(item4, null);
  });

  test("pending pushes are released one slot at a time", () async {
    var channel = Channel<int>(1);

    await channel.push(1);
    var push2Done = false;
    var push3Done = false;
    var push2 = channel.push(2).then((_) => push2Done = true);
    var push3 = channel.push(3).then((_) => push3Done = true);
    await pumpEventQueue();

    expect(channel.currentSize, 1);
    expect(push2Done, isFalse);
    expect(push3Done, isFalse);

    expect(await channel.pop(), 1);
    await pumpEventQueue();

    expect(channel.currentSize, 1);
    expect(push2Done, isTrue);
    expect(push3Done, isFalse);

    expect(await channel.pop(), 2);
    await Future.wait([push2, push3]);

    expect(channel.currentSize, 1);
    expect(push3Done, isTrue);
    expect(await channel.pop(), 3);
  });
}
