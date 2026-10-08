# 设置规则拆分兼容说明 / Settings rule extraction compatibility

基线 `654e68f`。此提交独立配置编解码和关键词成员操作，沿用原存储队列、key和数据格式；行为缺陷单独跟进。

## 代理编辑配置 / Proxy editor configuration

`ProxyConfiguration`是不可变编辑模型，模式为`ProxyMode`；端口保持字符串，控件仍使用原int.tryParse校验。`network/proxy.dart`消费原字符串并解析平台system返回值，语义不同，本轮未合并或修改它。

| 输入/操作 | 保留行为 |
|---|---|
| 精确`direct` / `system` | 对应模式；大小写和空白不归一化。 |
| `user:pass@host:80` | 四字段往返，Unicode/空白/端口前导零或加号保留。 |
| `host:` | 空端口序列化为`host`。 |
| `user:@host:80` | 空密码序列化为`user@host:80`。 |
| `:pass@host:80` | 无用户名时不输出密码。 |
| 单独host、username无密码、IPv6或额外分隔符 | 原split长度判断保留，因此部分字段仍无法往返。纯配置模型不是URL/URI或系统代理解析器。 |
| 手动→系统/直连→手动 | 模式切换保留未提交手动字段；系统/直连立即加入原保存队列。 |
| 保存期间字段或模式变化 | 原选择代次与字符串比较继续阻止旧保存结果关闭当前表单。 |

没有修复host-only、username-only和IPv6编辑兼容，尚需设计无歧义的旧值迁移及运行时匹配方案。直接加载不改存储。纯Dart探针对基线提取的原方法比较587个解析输入与243组序列化字段；它只证明此语料内行为相同，不宣称覆盖所有字符串。

## 关键词成员编辑 / Keyword membership editing

`BlockedKeywordList`集中原`blockedWords`和`blockedCommentWords`两个键。`KeywordSettingsStore`注入已有设置端口及更新队列，无Appdata/Widget依赖；构造不启动任务。生产页面负责监听、输入、提示、路由和队列装配。

- 入队只捕获目标、word和增删意图；获准执行时从草稿复制当前列表，避免覆盖其他排队编辑。
- 添加只在不存在时追加，删除移除所有相等项，保留其他成员顺序及既有重复项。
- 区分大小写及空白，允许空字符串，沿用原List<String>.from的类型错误；不自动清空或修复非法旧列表。重复提示仍按原始List.contains检查。
- 返回原队列Future，实际持久化完成前不报告完成；失败保留原异常/堆栈，显式重试使用新草稿。
- 读取列表为独立副本，不改变原存储；UI存活检查、排队保存、失败重试与窗口退出所有权继续由现有组件负责。

纯服务回归涵盖两列表的排队合并、重复添加、删除重排、持久化等待、读所有者替换、快照隔离、异常/堆栈和非法类型；既有真实临时目录/页面测试继续验证生产接线。未迁移漫画/评论过滤的所有消费端，也未宣称全配置类型化或全域生命周期完成。

The extraction retains saved keys, raw text and existing queue semantics. The codec is specific to the editor and does not replace runtime system-proxy parsing. Keyword changes resolve membership against the admitted draft; they do not save a captured whole-list snapshot. Malformed configuration recovery, remaining consumers and platform validation remain open.
