# VeneraNext 无头命令模式

英文版本：[headless.en.md](headless.en.md)

VeneraNext 的无头命令模式允许从命令行运行部分关键功能，适合自动化任务或与其他工具集成。本文档说明当前可用命令和输出格式。

## 使用方式

运行 VeneraNext 可执行文件时添加 `--headless` 参数，并跟随需要执行的命令。

```bash
venera-next --headless <command> [subcommand] [options]
```

## 全局选项

- **`--ignore-disheadless-log`**：抑制日志输出，使脚本解析输出时更干净。

## 命令

### `webdav`

管理 WebDAV 数据同步。

- **`webdav up`**：上传本地配置到 WebDAV 服务器。
- **`webdav down`**：下载并应用 WebDAV 服务器上的远端配置。

**示例：**

```bash
venera-next --headless webdav up
```

### `updatescript`

更新漫画源脚本。

- **`updatescript all`**：检查并应用所有可用的漫画源脚本更新。

**示例：**

```bash
venera-next --headless updatescript all
```

**输出格式：**

`updatescript` 会输出详细进度和最终汇总。

**进度日志：**

- **`Progress`**：单个脚本更新成功。
- **`ProgressError`**：某个脚本更新失败。

**`Progress` 日志示例：**

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

**最终汇总：**

命令结束时会输出脚本总数、更新数量和失败数量。

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

更新已追更漫画，并返回发生更新的漫画列表。

- **`updatesubscribe`**：检查所有已追更漫画。
- **`updatesubscribe --update-comic-by-id-type <id> <type>`**：更新指定 `id` 和 `type` 的单个漫画。

**示例：**

```bash
# 更新全部追更
venera-next --headless updatesubscribe

# 更新单个漫画
venera-next --headless updatesubscribe --update-comic-by-id-type "comic-id" "source-key"
```

## 输出格式

所有无头命令都会输出带 `[CLI PRINT]` 前缀的 JSON 对象。该结构便于自动化脚本解析。JSON 对象始终包含 `status` 和 `message`，返回数据时还会包含 `data` 字段。

### `updatesubscribe` 输出

`updatesubscribe` 会用 JSON 输出详细进度和最终结果。

**进度日志：**

更新过程中会收到 `Progress` 或 `ProgressError` 消息。

- **`Progress`**：表示更新流程中的一个步骤成功。
- **`ProgressError`**：表示更新某个漫画时发生错误。

**`Progress` 日志示例：**

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

**`ProgressError` 日志示例：**

```json
{
  "status": "running",
  "message": "ProgressError",
  "data": {
    "current": 2,
    "total": 10,
    "comic": {
      "id": "another-comic-id",
      "name": "Another Comic Name"
    },
    "error": "Error message here"
  }
}
```

**最终输出：**

更新完成后会返回最终 JSON 对象，其中 `data` 是本次检测到更新的漫画列表。

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
```

## 参数校验与失败结果

参数在核心初始化和应用数据访问前校验。仅接受本文列出的完整命令形式；缺失参数、未知命令、无效子命令和多余参数均输出 error 并以 1 退出。此前被忽略的多余参数现在会被拒绝。日志开关 --ignore-disheadless-log 可以放在 --headless 前或命令参数之间；漫画 id/source-key 不得为空或以 -- 开头。

脚本更新检查失败不会报告“没有更新”。可更新的源仍会继续处理；任一检查或更新失败，最终 status 为 error、退出码为 1。更新汇总保留 total/updated/errors（errors 仅统计更新失败），检查错误通过可选 data.checkErrors 字符串数组返回。没有更新且没有检查错误时仍成功退出。

订阅更新未配置文件夹、指定漫画不存在、单项/批量更新失败或命令执行异常均以 1 退出；部分失败时保留已成功更新的数据及列表输出，最终 status 为 error。成功命令以 0 退出。进度行的 ProgressError 不是终态，应以最终 status 和进程退出码判断结果。

订阅命令统一在更新完成后立即读取已提交的漫画列表，不再固定等待 500 毫秒。单漫画取消输出 ProgressError 并以 error/1 结束；批量进度流没有报告初始状态或在 current 小于 total 时结束，输出 Subscription update did not complete. 并以 1 退出，不生成成功列表终态。已完成的部分写入不会撤销。
