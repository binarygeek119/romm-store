import 'package:flutter_test/flutter_test.dart';
import 'package:romm_store/core/ps2/ps2_game_id_catalog.dart';

void main() {
  test('normalizedSerialKeys parses SLUS-20974 and SLUS_209.74 forms', () {
    expect(
      Ps2GameIdCatalog.normalizedSerialKeys('foo SLUS-20974 bar').toList(),
      containsAll(['SLUS_209.74']),
    );
    expect(
      Ps2GameIdCatalog.normalizedSerialKeys('prefix SLUS_209.74 suffix').toList(),
      containsAll(['SLUS_209.74']),
    );
  });
}
