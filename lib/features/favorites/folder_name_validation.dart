import 'package:venera_next/foundation/translations.dart';

String? validateFolderName(
  String newFolderName, {
  required Iterable<String> folders,
}) {
  if (newFolderName.isEmpty) {
    return "Folder name cannot be empty".tl;
  } else if (newFolderName.length > 50) {
    return "Folder name is too long".tl;
  } else if (folders.contains(newFolderName)) {
    return "Folder already exists".tl;
  }
  return null;
}
