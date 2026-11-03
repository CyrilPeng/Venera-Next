import 'package:venera_next/foundation/translations.dart';
import 'favorite_folder_name.dart';

String? validateFolderName(
  String newFolderName, {
  required Iterable<String> folders,
  String? currentName,
}) {
  if (newFolderName.isEmpty) {
    return "Folder name cannot be empty".tl;
  } else if (newFolderName.length > 50) {
    return "Folder name is too long".tl;
  } else if (hasFavoriteFolderName(
    folders,
    newFolderName,
    excluding: currentName,
  )) {
    return "Folder already exists".tl;
  }
  return null;
}
