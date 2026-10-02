# VeneraNext Headless Mode

VeneraNext's headless mode allows you to run key features from the command line, making it easy to automate tasks and integrate with other tools. This document outlines the available commands and their usage.

## How to Use

To activate headless mode, use the `--headless` flag when running the VeneraNext executable, followed by the desired command.

```bash
venera-next --headless <command> [subcommand] [options]
```

## Global Options

- **`--ignore-disheadless-log`**: Suppresses log output, providing a cleaner output for scripting.

## Commands

### `webdav`

Manage WebDAV data synchronization.

- **`webdav up`**: Uploads your local configuration to the WebDAV server.
- **`webdav down`**: Downloads and applies the remote configuration from the WebDAV server.

**Example:**

```bash
venera-next --headless webdav up
```

### `updatescript`

Update comic source scripts.

- **`updatescript all`**: Checks for and applies all available updates for your comic source scripts.

**Example:**

```bash
venera-next --headless updatescript all
```

**Output Format:**

The `updatescript` command provides detailed progress and a final summary.

**Progress Logs:**

- **`Progress`**: Indicates a successful update for a single script.
- **`ProgressError`**: Indicates a failure during a script update.

**Example `Progress` Log:**

```json
{
  "status": "running",
  "message": "Progress",
  "data": {
    "current": 1,
    "total": 5,
    "source": {
      "key": "source-key",
      "name": "Source Name",
      "version": "1.0.0",
      "url": "https://example.com/source.js"
    }
  }
}
```

**Final Summary:**

A summary is provided at the end, detailing the total number of scripts, how many were updated, and how many failed.

```json
{
  "status": "success",
  "message": "All scripts updated.",
  "data": {
    "total": 5,
    "updated": 4,
    "errors": 1
  }
}
```

### `updatesubscribe`

Update your subscribed comics and retrieve a list of updated comics.

- **`updatesubscribe`**: Checks all subscribed comics for updates.
- **`updatesubscribe --update-comic-by-id-type <id> <type>`**: Updates a single comic specified by its `id` and `type`.

**Example:**

```bash
# Update all subscriptions
venera-next --headless updatesubscribe

# Update a single comic
venera-next --headless updatesubscribe --update-comic-by-id-type "comic-id" "source-key"
```

## Output Format

All headless commands output JSON objects prefixed with `[CLI PRINT]`. This structured format allows for easy parsing in automated scripts. The JSON object always contains a `status` and a `message`. For commands that return data, a `data` field will also be present.

### `updatesubscribe` Output

The `updatesubscribe` command provides detailed progress and final results in JSON format.

**Progress Logs:**

During an update, you will receive `Progress` or `ProgressError` messages.

- **`Progress`**: Indicates a successful step in the update process.
- **`ProgressError`**: Indicates an error occurred while updating a specific comic.

**Example `Progress` Log:**

```json
{
  "status": "running",
  "message": "Progress",
  "data": {
    "current": 1,
    "total": 10,
    "comic": {
      "id": "some-comic-id",
      "name": "Some Comic Name",
      "coverUrl": "https://example.com/cover.jpg",
      "author": "Author Name",
      "type": "source-key",
      "updateTime": "2023-10-27T12:00:00Z",
      "tags": ["tag1", "tag2"]
    }
  }
}
```

**Example `ProgressError` Log:**

```json
{
  "status": "running",
  "message": "ProgressError",
  "data": {
    "current": 2,
    "total": 10,
    "comic": {
      "id": "another-comic-id",
      "name": "Another Comic Name",
      ...
    },
    "error": "Error message here"
  }
}
```

**Final Output:**

Once the update process is complete, a final JSON object is returned with a list of all comics that have been updated.

```json
{
  "status": "success",
  "message": "Updated comics list.",
  "data": [
    {
      "id": "some-comic-id",
      "name": "Some Comic Name",
      "coverUrl": "https://example.com/cover.jpg",
      "author": "Author Name",
      "type": "source-key",
      "updateTime": "2023-10-27T12:00:00Z",
      "tags": ["tag1", "tag2"]
    }
  ]
}

## Argument validation and failures

Arguments are validated before core initialization or application-data access. Only the documented complete command forms are accepted. Missing, unknown, invalid or extra arguments produce error and exit code 1; previously ignored trailing arguments are now rejected. --ignore-disheadless-log may appear before --headless or among command arguments. Comic id/source-key values must be nonempty and must not start with --.

A failed script-update check is no longer reported as no updates. Available updates are still attempted; any check or update failure produces final status error and exit code 1. Summaries retain total/updated/errors (errors counts update failures only); optional data.checkErrors contains check-error strings. No updates with no check failures remains a success.

Subscription updates exit with 1 for a missing folder configuration, missing selected comic, individual/batch update failures or command exceptions. Partial failures retain successful updates and list output, with final status error. Successful commands exit with 0. A ProgressError progress line is not terminal; inspect final status and process exit code.

Subscription commands read the committed comic list immediately after updates finish, without a fixed 500 ms delay. Single-comic cancellation emits ProgressError and ends with error/1. A batch stream that reports no initial state or closes with current below total emits Subscription update did not complete. and exits with 1 instead of a successful list result. Completed partial writes are not rolled back.
