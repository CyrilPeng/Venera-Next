# Keyword blocking and match reasons

[简体中文](keyword_blocking.zh.md)

> These features are available for testing in `v1.18.4-rc.1+250`. The current stable release, `v1.18.3+249`, still uses the original keyword matching and does not include match modes, trial matching, or editing from the reasons dialog.

## 1. Add or edit a rule

Open **Settings → Explore → Keyword blocking** to add a rule, or click an existing keyword to edit it. **Comment keyword blocking** on the same page manages a separate list.

Each rule has a keyword, a matching method, and an **Ignore case** switch. New rules ignore case by default. When you enter 1–3 English letters, the editor recommends **Whole word**. You can choose another method; typing more text then keeps your choice.

| Method | Suitable content | Fields checked |
|---|---|---|
| Contains text | Chinese phrases, longer author names, or specific text fragments | Substrings in the title, subtitle, and description; tags must match exactly |
| Whole word | Short abbreviations such as `BL` that can also occur within longer words | Independent text in the title, subtitle, and description; tags must match exactly |
| Exact tag | A tag you want to block without checking the title | A complete tag or its name after the namespace; comics without tags do not match |

Comment rules offer **Contains text** and **Whole word**, checking only the comment body. Keywords are always literal text: `a.b`, `[BL]`, and `a+b` mean those exact characters. No regular-expression syntax is required.

## 2. Avoid accidental matches from short abbreviations

For the keyword `bl` with **Ignore case** enabled:

| Sample title | Contains text | Whole word |
|---|---|---|
| `black and white` | Hidden | Visible |
| `[BL] Short stories` | Hidden | Hidden |
| `artist.bl.part01.zip` | Hidden | Hidden |
| `BL_stories` | Hidden | Hidden |
| `BL漫画` | Hidden | Visible |

Spaces, punctuation, dots, and underscores separate whole words. Adjacent Unicode letters, numbers, and combining marks do not. Whole-word matching does not segment Chinese text, which usually has no spaces between words. Use **Contains text** to match `校园` within `校园恋爱故事`.

Exact-tag matching is independent of the title. `bl` matches `BL` or `genre:BL`, but not `black` or `BL stories`. To preserve the existing tag format, a tag with several colons uses only the first segment after the first colon: `genre:BL:other` matches `bl`; `genre:other:BL` does not.

## 3. Try a rule before saving

Click **Test match** in the editor and enter a sample title, tag, or comment. The preview shows **Will be hidden** or **Will stay visible** and highlights the matched text. It uses the same matching logic as the lists.

The trial checks only the current rule and your sample. Sample text is not saved as a keyword. Click **Add** or **Save** to apply the rule. If saving fails, your edit remains available for retry. If another window has changed or deleted the rule, the editor asks you to reopen it so an older edit cannot overwrite the newer setting.

## 4. Find out why a comic is hidden

Click **Hidden by keyword filters: … comics** in a comic list to view reasons. Each entry shows text from a comic in the current list, the first rule that actually matched, its field, matching method, and case setting. The matching text is highlighted; hidden covers remain hidden.

Click **Edit rule** to change that rule directly. Saving recalculates the reasons and updates the comic list. If the comic remains hidden, another rule may still match; check the reasons again. The count covers only comics already loaded in the current list, rather than the entire library.

The comic card's **Block** shortcut uses **Exact tag** for newly selected tags, **Whole word** for 1–3 English letters, and **Contains text** for other text, ignoring case by default. Existing keywords keep their current rules. You can adjust them further in keyword settings.

## 5. Existing rules, backups, and synchronization

Upgrading does not automatically change old rules. Existing comic keywords retain case-sensitive substring matching and exact tag matching; existing comment keywords retain case-insensitive substring matching. Saving an old rule without changes also keeps its original behavior.

If an old `bl` rule hides `black`, edit it, choose **Whole word**, enable **Ignore case** if desired, and test both `black` and `[BL]` before saving.

A complete app-data backup preserves both keywords and matching methods. Excluding a keyword list from app-data synchronization also excludes its matching methods. Comic and comment lists are handled separately. Importing an older backup with only a word list restores the original matching behavior for that list.

Older app versions cannot use the new methods and apply their original substring matching. Devices sharing data should use versions that support this feature. Keep a separate complete backup before downgrading to prevent an older version's synchronization from overwriting newer rules.
