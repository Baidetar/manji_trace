import 'package:flutter_test/flutter_test.dart';
import 'package:manji_trace/controllers/sync_service.dart';

void main() {
  test('should mark rebase for chain-gap reason', () {
    expect(
      SyncService.shouldMarkDeltaChainRebaseReason('delta-chain-gap-at-123'),
      true,
    );
  });

  test('should mark rebase for invalid fallback manifest reason', () {
    expect(
      SyncService.shouldMarkDeltaChainRebaseReason(
          'delta-chain-gap-at-42|fallback-json-invalid'),
      true,
    );
    expect(
      SyncService.shouldMarkDeltaChainRebaseReason('fallback-range-mismatch'),
      true,
    );
  });

  test('should not mark rebase for non-corruption reasons', () {
    expect(
      SyncService.shouldMarkDeltaChainRebaseReason('delta-cursor-too-old'),
      false,
    );
    expect(
      SyncService.shouldMarkDeltaChainRebaseReason('delta-digest-mismatch'),
      false,
    );
    expect(
      SyncService.shouldMarkDeltaChainRebaseReason('delta-parse-failed'),
      false,
    );
  });
}
