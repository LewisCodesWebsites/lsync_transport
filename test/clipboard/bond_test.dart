import 'dart:io';

import 'package:lsync_transport/lsync_transport.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late TrustStore store;
  late ClipboardBond bond;

  final laptop = 'a' * 64;
  final desktop = 'b' * 64;
  final stranger = 'c' * 64;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lsync-bond-');
    store = await TrustStore.open(directory.path);
    await store.pin(laptop, 'laptop');
    await store.pin(desktop, 'desktop');
    bond = ClipboardBond(store);
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('there is no bond until one is made', () {
    expect(bond.isBonded, isFalse);
    expect(bond.partner, isNull);
    expect(bond.isPartner(laptop), isFalse);
  });

  test('bonding names exactly one partner', () async {
    await bond.bondTo(laptop);
    expect(bond.partner, laptop);
    expect(bond.isPartner(laptop), isTrue);
    expect(bond.isPartner(desktop), isFalse,
        reason: 'D-03: one pair at a time');
  });

  test('switching replaces rather than adds (D-03)', () async {
    await bond.bondTo(laptop);
    await bond.bondTo(desktop);
    expect(bond.partner, desktop);
    expect(bond.isPartner(laptop), isFalse);
  });

  test('an unpaired device cannot be bonded', () async {
    // A clipboard bond to an unpinned fingerprint would be a channel to a
    // device nobody ever confirmed.
    await expectLater(
      () => bond.bondTo(stranger),
      throwsA(isA<ArgumentError>()),
    );
    expect(bond.isBonded, isFalse);
  });

  test('releasing drops the bond without unpairing', () async {
    await bond.bondTo(laptop);
    await bond.release();
    expect(bond.isBonded, isFalse);
    expect(store.isPinned(laptop), isTrue,
        reason: 'file transfer to that device must still work (D-03)');
  });

  test('unpairing the partner clears the bond', () async {
    await bond.bondTo(laptop);
    await store.unpin(laptop);
    expect(bond.isBonded, isFalse,
        reason: 'a bond to a device that is no longer paired is not a bond');
  });

  test('the bond survives a reload, because it is the one thing stored', () async {
    await bond.bondTo(desktop);
    final reopened = ClipboardBond(await TrustStore.open(directory.path));
    expect(reopened.partner, desktop);
  });
}
