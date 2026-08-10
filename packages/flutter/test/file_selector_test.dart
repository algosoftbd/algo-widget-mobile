import 'package:algo_widget/algo_widget.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

void main() {
  group('file selector', () {
    test('a local path becomes a file:// URI, not a relative one', () {
      // XFile.path is a plain filesystem path. Handed back unchanged it is a
      // RELATIVE URI, which the WebView resolves against the frame's own https
      // origin — so the attachment silently resolves to nothing.
      final uri = fileUri(XFile('/data/user/0/com.acme/cache/shot 1.png'));
      expect(uri, startsWith('file:///'));
      expect(Uri.parse(uri).scheme, 'file');
      // ...and a space in a filename is a real one, from a real gallery.
      expect(uri, contains('%20'));
    });

    test('a custom selector is honoured for both modes', () async {
      final seen = <FileSelectorMode>[];
      Future<List<String>> fake(FileSelectorParams p) async {
        seen.add(p.mode);
        return ['file:///tmp/a.png'];
      }

      const single = FileSelectorParams(
        isCaptureEnabled: false,
        acceptTypes: ['image/*'],
        mode: FileSelectorMode.open,
      );
      const many = FileSelectorParams(
        isCaptureEnabled: false,
        acceptTypes: ['image/*', 'audio/*', 'video/*'],
        mode: FileSelectorMode.openMultiple,
      );

      expect(await fake(single), hasLength(1));
      expect(await fake(many), hasLength(1));
      expect(seen, [FileSelectorMode.open, FileSelectorMode.openMultiple]);
    });

    test('the signature is the one Android calls', () {
      // Guards the shape rather than the behaviour: setOnShowFileSelector takes
      // exactly this function type, and a drifting typedef fails to compile at
      // the call site inside the panel — where there is no test that runs.
      const AlgoFileSelector selector = defaultFileSelector;
      expect(
          selector, isA<Future<List<String>> Function(FileSelectorParams)>());
    });
  });
}
