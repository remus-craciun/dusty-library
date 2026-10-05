import 'package:file_picker/file_picker.dart';
import 'package:file_picker_web/file_picker_web.dart';

/// Web: disable the "cancel on window blur" heuristic.
///
/// With it enabled the plugin treats the window regaining focus as a cancel.
/// Chrome frequently fires `focus` before the input's `change` event when the
/// native dialog closes, which drops the selection and makes "Add book" do
/// nothing. The `cancel` event of the input still handles real cancels.
WebOptions pickerWebOptions() =>
    const FilePickerWebOptions(cancelUploadOnWindowBlur: false);
