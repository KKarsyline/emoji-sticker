# Emoji Reactions

聊天消息的双向 emoji 贴纸。模型通过回复开头的标记给用户消息贴表情；用户选择的表情随下一条消息传给模型，无需额外工具调用或模型请求。

## 文件

- [message_reactions.py](message_reactions.py)：Python 流式解析器、emoji 校验和反向提示函数。
- [ReactionSticker.swift](ReactionSticker.swift)：SwiftUI 贴纸、弹出动画、表情选择器和本地保存。需要 iOS 17+ / macOS 14+。

代码需要接入现有聊天应用的消息流和存储。其他前端可只使用 Python 部分。

## 模型给用户贴表情

在模型提示词中加入：

```text
你可以给用户本轮消息贴一个 emoji。
想贴时，在回复最开头输出 <react>一个emoji</react>，然后正常回复。
不想贴就正常回复。每次最多一枚，只放在开头，无需调用工具。
收到 user posted: 后的 emoji，表示用户给你上一条回复贴了该表情。
```

Python 3.9+，安装依赖：

```bash
python -m pip install emoji==2.16.0
```

每条回复新建一个解析器，将正文字符串分片交给 `feed()`：

```python
from message_reactions import ReactionPrefixParser

parser = ReactionPrefixParser()
for chunk in ["<re", "act>😽", "</react>你好"]:
    visible, reaction = parser.feed(chunk)
    if reaction is not None:
        print("贴纸：", reaction)  # 接入表情保存和事件发送
    if visible:
        print("正文：", visible)  # 接入正文保存和流式发送

tail = parser.finish()
if tail:
    print("正文：", tail)
```

### 流式隐藏

解析器暂存可能属于开头标签的分片，完整识别后，将 emoji 与正文分开返回。上例的前两片没有可见输出，第三片返回贴纸 `😽` 和正文 `你好`。

**原始分片必须先经过解析器，只有返回的 `visible` 才能发送给前端。这样合法标签不会在流式正文里闪现。**

只识别开头第一个合法标记，允许前置空白，候选前缀上限为 128 字符。正文中间的标签、错误格式和不完整标记保留为文字。结束、报错或取消时都需要调用 `finish()` 处理残片。

如果接口仅在结束时返回全文，且此前没有收到任何非空正文分片，可将全文交给同一个解析器处理。已有分片时不要重复拼入全文；只有贴纸、没有正文的回复也有效。

### 关联消息

由后端填写本轮用户消息的准确 ID，表情跟随产生它的 assistant 回复保存：

```json
{"type":"reaction","target_message_id":"user-123","emoji":"😽"}
```

保存成功后，通过现有事件流将表情、会话 ID 和来源 assistant 消息 ID 发送给前端。前端核对归属，将贴纸显示到目标气泡上。历史与重连时恢复同一份数据；后续更新正文时保留表情字段，分支切换时只显示当前分支的表情。

## 用户给模型贴表情

SwiftUI 使用 `ReactionStore` 按会话和 assistant 消息保存选择，传入 `nil` 可撤掉：

```swift
ReactionStore.shared.setReaction(
    "🥺", conversationID: conversationID,
    assistantMessageID: assistantMessageID
)

// 发送下一条消息时读取。
let reaction = ReactionStore.shared.reactionForNextMessage(
    conversationID: conversationID,
    parentMessageID: parentMessageID
)
```

将可选的 `reaction` 放进现有请求的 `user_reaction` 字段：

```json
{"user_reaction":{"target_message_id":"assistant-456","emoji":"🥺"}}
```

Swift 网络编码使用 `JSONEncoder.keyEncodingStrategy = .convertToSnakeCase`，解码使用 `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`，与 `MessageReaction.targetMessageId` 对应。

后端先用 `is_valid_user_reaction_payload(target, emoji)` 校验字段，并确认目标是本次请求的准确父消息、属于当前会话且为用户有权访问的 assistant 消息。通过后，在送给模型的用户文字前加提示：

```python
from message_reactions import user_reaction_prefix

model_text = user_reaction_prefix("🥺") + original_user_text
# user posted:🥺\n + 用户本轮文字
```

这个提示只进入模型输入，不修改保存的用户原文和附件。点击表情本身不请求模型，下一条消息发送时才携带准确父消息上的表情。本地保存使用 `UserDefaults`，不包含跨设备同步。

## SwiftUI 显示

将 Swift 文件加入 app target，在目标气泡上添加修饰器：

```swift
Text("消息正文")
    .padding()
    .reactionSticker(ReactionDisplay(
        emoji: "😽", sourceKey: assistantMessageID, isLive: true
    ))
    .padding(.bottom, 18)
```

- `sourceKey` 使用产生表情的稳定 assistant 消息 ID；实时事件设 `isLive: true`，历史恢复设 `false`。
- 贴纸伸出气泡下缘，需要留出消息间距，避免被父视图裁剪。
- `ReactionEmojiPicker { emoji in ... }` 可放进自己的弹窗，选择后调用 `setReaction()`。
- `ReactionStore.shared.reactions(for: conversationID)[assistantMessageID]` 可读取用户保存的表情。
- `.reactionSticker(display, style: .glass) { ... }` 可显示磨砂贴纸，并在点击回调中撤掉表情。
- 大小、底色和位置在 `ReactionStickerStyle` 中调整。
