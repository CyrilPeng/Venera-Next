# 图片收藏时间范围兼容说明

本修复保留 `image_favorites_time_filter` 键及 `end:duration` 字符串结构。`duration` 为毫秒；`end` 为完整 Unix epoch 毫秒，或表示滚动范围的 `null`。不改数据库或文件布局，不在读取时重写旧数据。

| 输入 | 修复后的行为 |
|---|---|
| `null:0` | 全部 |
| `null:604800000` 等预设 | 恢复滚动范围，终点仍随当前时间变化 |
| 非预设的非负滚动时长 | 保留原时长；打开自定义编辑器但未改日期时仍按滚动范围保存 |
| 完整 epoch 毫秒与有效时长 | 保留时间点与时长；格式不存储时区标签，UTC 输入恢复为同一时间点的本地表示 |
| 旧版写出的 `0..999:duration` | 旧 writer 只保存 `DateTime.millisecond`，已丢失日期且无法恢复；回退为全部，用户可以重新选择 |
| 错误类型、格式、负时长、整数溢出或无法表示的起止日期 | 安全回退为全部 |

日期精度仍为毫秒。起点不包含、终点包含；零时长保持原来的无起点限制语义。滚动范围的 `contains` 原有未来时间处理不变。历史日期或未来日期可打开编辑器，不再因默认选择界限触发断言。

新选自定义范围时必须选齐两端日期才能确认。取消日期选择不修改原范围；选择日期后将滚动范围转为固定范围。日期选择返回及父页面更新前检查组件存活，避免更新已销毁页面。

旧版本的 parser 能读取修复后的完整 epoch 自定义值，但旧 writer 再次保存仍会截断日期；旧 parser 仍无法恢复 `null:duration`。降级不能保证筛选往返正确，重新升级后仍需重选已被旧版截断的日期。本修复没有推测或迁移丢失的日期。

显式保存继续调用原 `appdata.writeImplicitData()` 队列，仍未等待写入完成再关闭对话框；全域写入快照、失败反馈及生命周期所有权属于剩余 P4 工作。回归通过临时目录、真实 SQLite、保存后 JSON 读取与页面重建验证，不访问个人数据。

English: The existing key and `end:duration` shape are retained. Fixed ends use full epoch milliseconds; `null` retains a moving end. Invalid values, overflow and unrecoverable legacy millisecond fragments fall back to All without rewriting storage on read. Untouched non-preset rolling ranges remain rolling; editing a date makes them fixed. Start-exclusive/end-inclusive and zero-duration behavior stay unchanged. Old readers can parse fixed epoch values, but old writers corrupt them again and old readers still reject rolling values. No lost dates are inferred. The existing unawaited persistence call remains a P4 follow-up.
