# 评论标记解析与呈现边界

`foundation/comment_markup.dart` 解析评论文本，返回不可变的文本片段、按嵌套顺序排列的标签与属性、图片地址及关联链接。它仅依赖字符串 URL 检查，不依赖 Flutter、全局应用对象、手势识别器或页面导航。

`components/rich_comment_content.dart` 继续负责主题样式、TextSpan、手势识别器的创建与释放、图片控件以及原页面的链接跳转。解析模型不持有回调、BuildContext 或原生资源，不提供兼容转导出。

| 现有输入规则 | 本次保持的行为 |
|---|---|
| CRLF、`&amp;` | 转为 LF、`&`；其他实体不额外解码 |
| `b/i/u/s/strong/span/a` | 大小写敏感，按原标签栈顺序保留属性；主题样式仍由 UI 决定 |
| 显式链接 | 保留 href；UI 使用原 URL 规则决定是否创建识别器 |
| 自动链接 | 仅在没有活动 a 标签时识别；沿用原字符范围和 URL 校验；独立于外围格式标签渲染 |
| img | 保留原 src 和出现顺序；关联第一个外围 a 标签；无 src 不生成图片 |
| br、结束 br、自闭合 br | 前两种写换行；`<br/>` 仍按原规则保留为文本 |
| 未知标签、不匹配闭合标签 | 按原规则保留文字，不转换成标准 HTML 树 |
| 属性中的空格和等号 | 保留原空格分词、等号拆分及双引号去除行为；本次不改成通用 HTML 属性解析 |

模型的列表、标签序列和属性均复制并限制修改，后续扫描不会改变已生成片段。解析后的样式合并方法和图片构建方法与迁移前一致。16 个样本在深浅主题下产生的 32 组实际 TextSpan 属性与链接识别状态逐项对照相等；图片模型的顺序与关联另由纯逻辑测试验证。

这是职责分离，不是 HTML 语义修复或所有畸形输入验收。空白标签名仍可能触发原解析路径的越界异常；属性、实体、错误分类及完整源兼容矩阵属于 P7 后续工作。组件被登记为 UI 也不代表其全部资源生命周期已验收。

English: `parseCommentMarkup` returns immutable text runs, ordered tags/attributes and linked images without Flutter or global state. The renderer retains theme mapping, recognizers, images and route ownership. This extraction preserves the existing comment dialect, including its nonstandard attribute splitting, entities, break forms and auto-link styling; it does not claim general HTML compliance or malformed-input completion. Empty tag names and the full compatibility/error matrix remain follow-ups.
