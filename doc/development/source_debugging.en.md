# Local Source Debugging

中文：[漫画源本地调试](source_debugging.zh.md)

See the [Comic Source Guide](../api/comic_source.en.md) and [JavaScript API](../api/js.en.md) for extension contracts. This guide covers importing, editing, reloading, and diagnosing scripts.

Unified import, task reload, explicit editor save/reload, and asynchronous evaluator improvements are currently unreleased main-branch features. Version 1.16.0 retains the earlier URL/file import entry points. Start from the [minimal template](../examples/minimal_source.js), replacing its fictional service and mappings according to the [example API contract](../api/comic_source.en.md#1-script-and-minimal-example).

## Import and retry

1. Open Comic Source → Add source, choose a JS file or paste a raw script URL/contents, and install from the preview. Files are detected automatically; pasted input requires Detect and preview.
2. If installation fails, open task details to read and copy the complete error. JavaScript execution errors include the script path and line information supplied by the runtime.
3. Edit and save the original file, then select Retry. Accessible files are read again; URL tasks download the script again.
4. If the `key` is already installed, select Reload and confirm replacement. Successful file/URL tasks also offer Reload, so repeated development changes do not require uninstalling the source.

Some mobile file pickers supply a temporary copy. External changes do not update that copy; select the file again in that case. Pasted scripts have no original file to reread; use Edit script or paste the revised contents again. Files can also be imported again after clearing completed tasks. Use the normal Update action for repository upgrades.

## Edit an installed source

Select Edit script in the source menu:

- Desktop attempts to launch VS Code with a draft at `source_edit/<key>.js` under the app cache directory. Save in VS Code, then select Reload in the app. The dialog stays open for repeated edits and reloads.
- If VS Code is unavailable, or on mobile, use the built-in editor. Save and reload explicitly applies changes. Leaving unsaved text offers Keep editing or Discard changes.
- Syntax, field parsing, and `init()` errors remain visible. The previous source object, installed script, and local data from before initialization are preserved. The failed draft remains available for correction.
- Only the selected source is replaced. Other sources retain their runtime state. Keep the source `key` stable because favorites and history refer to it.

Drafts belong to the current editing session. Opening Edit script again creates a draft from the installed script. Keep development code that needs long-term retention in your own project directory.

Explicit installation and reload await `init()` for up to 15 seconds. Keep initialization short and avoid unbounded asynchronous work. At app startup, all sources are registered before their initializers run independently, so one source's network wait does not block the others from loading.

## JavaScript evaluator and logs

Open Settings → Debug. JS Evaluator displays ordinary values, awaits Promises, formats maps/lists, and allows copying results and errors. Run is disabled during execution. A pending evaluation times out after 30 seconds.

Try an asynchronous result:

```javascript
Promise.resolve({ chapters: 3, ready: true })
```

Inspect your installed source, replacing `example_source` with its actual key:

```javascript
ComicSource.sources.example_source.version
```

Wrap multiple asynchronous statements in an async function expression:

```javascript
(async () => {
    const source = ComicSource.sources.example_source;
    const details = await source.comic.loadInfo("your-test-comic-id");
    return details;
})()
```

Reload Configs reads installed scripts one at a time and reports aggregated errors. It does not read VS Code drafts; apply those with Reload in the editing dialog. Open Log shows request and script errors.

Class declarations may be indented, with `extends ComicSource` on another line. A class extending `ComicSource` and the fields `name`, `key`, and `version` are required. Keys start with a letter or underscore and contain only letters, digits, and underscores. Optional sections such as `search` and `account` may be omitted.

## Follow checks and cancellation limits

Follow checks allow 5 concurrent calls globally and 2 per source, with at least 500 milliseconds between starts for one source. There is no global pause after every 5 comics. Each comic has a 45-second deadline, including limited transient retries in the bridge; the follow layer no longer adds its own attempts.

Cancel, dismissing the progress dialog, or starting another check stops the old queue and bridge retries, ignores late results, and prevents subsequent favorite updates. Completed results remain. HTTP requests associated with a request scope are also cancelled.

QuickJS asynchronous dispatch does not always retain Dart request scopes. Cancellation therefore cannot guarantee termination of every subrequest an extension starts after subsequent JavaScript `await` statements, or interrupt a synchronous infinite loop. Evaluation and initialization timeouts do not kill the script either. Remote side effects cannot be rolled back. Bound internal request waits and retries, and avoid detached data writes from `init()`.
