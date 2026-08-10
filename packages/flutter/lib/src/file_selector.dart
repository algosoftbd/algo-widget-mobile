/// Attach, on Android.
///
/// An `<input type="file">` inside an Android WebView opens nothing. The
/// platform hands the decision to the embedder through
/// `WebChromeClient.onShowFileChooser`, and if the embedder does not answer,
/// the tap is simply dropped — no error, no dialog, no callback. That is why
/// Attach worked in React Native (react-native-webview implements it) and on
/// iOS (WKWebView presents its own picker) and did nothing at all in Flutter.
///
/// This is NOT a permissions problem, and adding a permission would be the
/// wrong fix. The system photo picker (Android 13+) and the Storage Access
/// Framework below it both grant access to the single item the user chose, at
/// the moment they chose it. There is no manifest entry to add and no runtime
/// prompt to request — a `READ_MEDIA_IMAGES` here would ask a customer's users
/// for their whole gallery in order to read one file they had already picked.
library;

import 'package:image_picker/image_picker.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Chooses files for the panel's Attach button. Returns the chosen items as
/// URI strings, or an EMPTY list when the reporter cancels.
///
/// Cancelling must return `[]` and never throw: Android's contract is that the
/// callback always answers, and a dropped answer leaves the WebView's file
/// input wedged for the rest of the session — the reporter's second tap on
/// Attach then does nothing either, which reads as the same bug again.
typedef AlgoFileSelector = Future<List<String>> Function(
    FileSelectorParams params);

/// The default picker: images and video through the system picker.
///
/// Scoped to media on purpose. The panel asks for `image/*,audio/*,video/*`,
/// and a bug report's attachment is in practice a screenshot or a screen
/// recording — while narration has its own first-class Record path rather than
/// arriving as an attached audio file. Media picking is also the part that
/// needs no permission; a general document picker is a bigger surface for a
/// case the panel barely has. An app that needs the rest passes its own
/// [AlgoFileSelector] to `AlgoWidgetPanel.fileSelector`.
Future<List<String>> defaultFileSelector(FileSelectorParams params) async {
  final picker = ImagePicker();
  try {
    if (params.mode == FileSelectorMode.openMultiple) {
      final picked = await picker.pickMultipleMedia();
      return picked.map(fileUri).toList();
    }
    final picked = await picker.pickMedia();
    return picked == null ? const [] : [fileUri(picked)];
  } catch (_) {
    // A picker that fails is a report without an attachment, never a panel
    // that cannot be used. The reporter still has their description, and the
    // Android callback is still answered.
    return const [];
  }
}

/// A local path as the `file://` URI the WebView expects back.
///
/// `XFile.path` is a plain filesystem path, and handing that over unchanged
/// yields a relative URI the WebView resolves against the frame's own https
/// origin — so the attachment silently resolves to nothing.
String fileUri(XFile file) => Uri.file(file.path).toString();
