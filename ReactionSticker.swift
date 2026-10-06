// Emoji 贴纸、选择器和本地保存。iOS 17+ / macOS 14+。
import SwiftUI
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct MessageReaction: Codable, Equatable, Sendable {
    let targetMessageId: String
    let emoji: String

    var isValid: Bool {
        guard !targetMessageId.isEmpty,
              targetMessageId.utf8.count <= 512,
              emoji.utf8.count <= 64,
              emoji.count == 1
        else { return false }
        let scalars = emoji.unicodeScalars
        let hasEmojiPresentation = scalars.contains { $0.properties.isEmojiPresentation }
        let hasEmojiScalar = scalars.contains { $0.properties.isEmoji }
        if hasEmojiPresentation { return true }
        if scalars.count == 1,
           let scalar = scalars.first,
           scalar.value > 0x7F,
           scalar.properties.isEmoji {
            return true
        }
        let hasEmojiSequenceMarker = scalars.contains {
            $0.value == 0xFE0F  // emoji presentation selector
                || $0.value == 0x20E3  // keycap
                || $0.value == 0x200D  // zero-width joiner
                || (0x1F1E6...0x1F1FF).contains($0.value)  // regional indicator
        }
        return hasEmojiScalar && hasEmojiSequenceMarker
    }
}


@MainActor @Observable
final class ReactionStore {
    static let shared = ReactionStore()
    static let persistenceKey = "EmojiShare.userReactions.v1"

    private let defaults: UserDefaults
    private(set) var reactionsByConversation: [String: [String: String]]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.persistenceKey),
              let saved = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else {
            reactionsByConversation = [:]
            return
        }

        var valid: [String: [String: String]] = [:]
        for (conversationID, reactions) in saved where !conversationID.isEmpty {
            for (assistantMessageID, emoji) in reactions
            where MessageReaction(targetMessageId: assistantMessageID, emoji: emoji).isValid {
                valid[conversationID, default: [:]][assistantMessageID] = emoji
            }
        }
        reactionsByConversation = valid
    }

    func reactions(for conversationID: String?) -> [String: String] {
        guard let conversationID, !conversationID.isEmpty else { return [:] }
        return reactionsByConversation[conversationID] ?? [:]
    }

    func reactionForNextMessage(
        conversationID: String?,
        parentMessageID: String?
    ) -> MessageReaction? {
        guard let conversationID, !conversationID.isEmpty,
              let parentMessageID, !parentMessageID.isEmpty,
              let emoji = reactionsByConversation[conversationID]?[parentMessageID]
        else { return nil }
        return MessageReaction(targetMessageId: parentMessageID, emoji: emoji)
    }

    @discardableResult
    func setReaction(
        _ emoji: String?,
        conversationID: String,
        assistantMessageID: String
    ) -> Bool {
        guard !conversationID.isEmpty, !assistantMessageID.isEmpty else { return false }
        if let emoji,
           !MessageReaction(targetMessageId: assistantMessageID, emoji: emoji).isValid {
            return false
        }

        var updated = reactionsByConversation
        if let emoji {
            updated[conversationID, default: [:]][assistantMessageID] = emoji
        } else {
            updated[conversationID]?.removeValue(forKey: assistantMessageID)
            if updated[conversationID]?.isEmpty == true {
                updated.removeValue(forKey: conversationID)
            }
        }
        guard let data = try? JSONEncoder().encode(updated) else { return false }
        defaults.set(data, forKey: Self.persistenceKey)
        reactionsByConversation = updated
        return true
    }
}

// 气泡右下角贴纸；同一回复的同一枚表情只播放一次入场动画。
struct ReactionDisplay: Equatable {
    let emoji: String
    // 来源回复的身份：落地后就是后端 assistant message_id，本地流式换成历史时保持不变。
    let sourceKey: String
    // 来自本地流式回复：第一次出现时播入场动画；历史里读到的直接静止显示。
    let isLive: Bool

    var revealKey: String { "\(sourceKey)|\(emoji)" }
}

struct ReactionStickerStyle {
    enum Material {
        case solid        // 纯色底 + 白圈
        case glass   // 系统磨砂玻璃
    }

    var material: Material = .solid
    var diameter: CGFloat
    var emojiSize: CGFloat
    var ringWidth: CGFloat = 1.2
    // 贴纸右缘离宿主右缘的距离。
    var trailingInset: CGFloat = 12
    // 贴纸顶端压进宿主下缘多少，其余垂在外面。
    var overlap: CGFloat = 14
    var fill: () -> Color = { Color(red: 0.98, green: 0.84, blue: 0.88) }
    var ring: () -> Color = { Color.white.opacity(0.92) }
    var shadowOpacity: Double = 0

    var drop: CGFloat { diameter - overlap }

    static var standard: ReactionStickerStyle {
        #if os(iOS)
        ReactionStickerStyle(diameter: 30, emojiSize: 17)
        #else
        ReactionStickerStyle(diameter: 28, emojiSize: 16)
        #endif
    }

    // 贴在 assistant 气泡上的：使用系统磨砂材质。
    static var glass: ReactionStickerStyle {
        var style = standard
        style.material = .glass
        return style
    }

    // 宿主右下角如果还挂着编辑/复制功能条，有贴纸时把它往左让出贴纸的位置。
    func actionBarOffset(for reaction: ReactionDisplay?, base: CGSize = .zero) -> CGSize {
        guard reaction != nil else { return base }
        return CGSize(width: base.width - diameter - trailingInset, height: base.height)
    }
}

// 入场动画只播一次：同一来源回复的同一枚表情，换会话、本地换成历史、cell 复用都不再重播。
@MainActor
enum ReactionStickerRevealLedger {
    static var played: Set<String> = []
}

struct ReactionSticker: View {
    let reaction: ReactionDisplay
    var style: ReactionStickerStyle = .standard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed: Bool
    @State private var popTrigger = 0
    private let animatesIn: Bool

    @MainActor
    init(reaction: ReactionDisplay, style: ReactionStickerStyle = .standard) {
        self.reaction = reaction
        self.style = style
        let animatesIn = reaction.isLive && !ReactionStickerRevealLedger.played.contains(reaction.revealKey)
        self.animatesIn = animatesIn
        _revealed = State(initialValue: !animatesIn)
    }

    private struct Pop: Sendable {
        var scale: CGFloat = 1
        var angle: Double = 0
        var emojiScale: CGFloat = 1
        var emojiAngle: Double = 0
        var emojiY: CGFloat = 0
    }

    var body: some View {
        let face = Face(emoji: reaction.emoji, emojiSize: style.emojiSize)
        Color.clear
            .frame(width: style.diameter, height: style.diameter)
            .background { disc }
            .keyframeAnimator(initialValue: Pop(), trigger: popTrigger) { content, pop in
                content
                    .overlay { face.view(pop) }
                    .scaleEffect(pop.scale)
                    .rotationEffect(.degrees(pop.angle))
            } keyframes: { _ in
                // 圆片转着弹出来；emoji 晚一拍冒头、歪一下脑袋再坐正。
                KeyframeTrack(\.scale) {
                    MoveKeyframe(0.2)
                    SpringKeyframe(1.0, duration: 0.5, spring: .init(response: 0.36, dampingRatio: 0.68))
                }
                KeyframeTrack(\.angle) {
                    MoveKeyframe(-16)
                    SpringKeyframe(0, duration: 0.55, spring: .init(response: 0.42, dampingRatio: 0.58))
                }
                // emoji 从圆心「啵」地蹦出来：冲到 1.2 倍、往上跳一下，再弹几下落回原位。
                KeyframeTrack(\.emojiScale) {
                    MoveKeyframe(0.01)
                    LinearKeyframe(0.01, duration: 0.12)
                    CubicKeyframe(1.2, duration: 0.14)
                    CubicKeyframe(0.95, duration: 0.12)
                    CubicKeyframe(1.03, duration: 0.11)
                    SpringKeyframe(1.0, duration: 0.3, spring: .init(response: 0.22, dampingRatio: 0.55))
                }
                KeyframeTrack(\.emojiY) {
                    MoveKeyframe(0)
                    LinearKeyframe(0, duration: 0.12)
                    CubicKeyframe(-3, duration: 0.14)
                    CubicKeyframe(0.5, duration: 0.12)
                    SpringKeyframe(0, duration: 0.3, spring: .init(response: 0.22, dampingRatio: 0.6))
                }
                KeyframeTrack(\.emojiAngle) {
                    MoveKeyframe(0)
                    LinearKeyframe(0, duration: 0.38)
                    CubicKeyframe(8, duration: 0.14)
                    CubicKeyframe(-3, duration: 0.14)
                    SpringKeyframe(0, duration: 0.3, spring: .init(response: 0.26, dampingRatio: 0.6))
                }
            }
            .opacity(revealed ? 1 : 0)
            .onAppear {
                guard animatesIn, !revealed else { return }
                ReactionStickerRevealLedger.played.insert(reaction.revealKey)
                if reduceMotion {
                    withAnimation(.easeOut(duration: 0.2)) { revealed = true }
                } else {
                    revealed = true
                    popTrigger += 1
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text(reaction.emoji))
    }

    @ViewBuilder
    private var disc: some View {
        switch style.material {
        case .solid:
            Circle()
                .fill(style.fill())
                .overlay {
                    Circle().strokeBorder(style.ring(), lineWidth: style.ringWidth)
                }
                .shadow(color: .black.opacity(style.shadowOpacity), radius: 3, y: 1)
        case .glass:
            Circle()
                .fill(.ultraThinMaterial)
                .overlay {
                    Circle().strokeBorder(style.ring(), lineWidth: style.ringWidth)
                }
        }
    }

    private struct Face: Sendable {
        let emoji: String
        let emojiSize: CGFloat

        // 整串 emoji 原样画（肤色 / 旗帜 / ZWJ 组合都是一个字形），不按 scalar 拆。
        nonisolated func view(_ pop: Pop) -> some View {
            Text(emoji)
                .font(.system(size: emojiSize))
                .lineLimit(1)
                .fixedSize()
                .scaleEffect(pop.emojiScale)
                .rotationEffect(.degrees(pop.emojiAngle))
                .offset(y: pop.emojiY)
        }
    }
}

extension View {
    // offset：贴纸锚点相对宿主右下角的额外位移（叠图消息用它挪到前景卡片右下）。
    // onTap：非 nil 时贴纸可点（点击可撤掉）；nil 时不拦任何点击。
    func reactionSticker(
        _ reaction: ReactionDisplay?,
        style: ReactionStickerStyle = .standard,
        offset: CGSize = .zero,
        onTap: (() -> Void)? = nil
    ) -> some View {
        overlay(alignment: .bottomTrailing) {
            if let reaction {
                ReactionSticker(reaction: reaction, style: style)
                    .id(reaction.revealKey)
                    .contentShape(Circle())
                    .onTapGesture { onTap?() }
                    .allowsHitTesting(onTap != nil)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                    .padding(.trailing, style.trailingInset)
                    .offset(x: offset.width, y: style.drop + offset.height)
            }
        }
    }
}

// 点笑脸弹出的小窗：一格一格的 emoji，点一个就贴。
struct ReactionEmojiPicker: View {
    let onPick: (String) -> Void

    private static let emojis: [String] = [
        "❤️", "🥰", "😘", "😍", "🥺", "🥹", "😭",
        "😂", "🤣", "😊", "😳", "😏", "😤", "😾",
        "😽", "😻", "🙀", "🐱", "🐾", "💋", "😈",
        "👍", "👏", "🙏", "🫶", "🤗", "💕", "💗",
        "✨", "🔥", "💯", "🎉", "🌹", "🍰", "🤍",
        "🤔", "🙄", "😴", "🤤", "😋", "😢", "😡",
        "🫠", "🫣", "🥵", "👀", "😮‍💨", "💔", "🌙",
    ].filter { MessageReaction(targetMessageId: "local", emoji: $0).isValid }

    private let columns = Array(repeating: GridItem(.fixed(38), spacing: 2), count: 7)

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Self.emojis, id: \.self) { emoji in
                    Text(emoji)
                        .font(.system(size: 24))
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(emoji) }
                        .accessibilityAddTraits(.isButton)
                }
            }
            .padding(10)
        }
        .frame(width: 7 * 38 + 6 * 2 + 20, height: 5 * 38 + 4 * 2 + 20)
    }
}
