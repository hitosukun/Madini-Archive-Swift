// TEMPORARY — Phase 2 benchmark only. Delete after the report is final.
// Synthetic markdown fixtures sized to match the rendered-message caps
// described in MessageBubbleView.swift (maxRenderedTextBlockLength = 12_000,
// maxRenderedMessageLength = 20_000).

import Foundation

enum Fixtures {
    /// Repeating Japanese paragraph corpus (≈40 chars per line).
    private static let jpLine = "これは検証用のサンプル文章であり、句読点や改行を含む通常の段落の挙動をシミュレートします。"

    /// Repeating English line for math/code mix where letter-heavy text matters.
    private static let enLine = "This sentence is filler text used to expand the message length to the desired character count for benchmark purposes."

    /// 2,000-char Japanese with one short code block.
    static func small() -> String {
        var s = "# 短い見出し\n\n"
        while s.count < 1_700 {
            s += jpLine + "\n\n"
        }
        s += "```swift\nfunc hello() { print(\"hi\") }\nlet x = 1\n```\n\n"
        return s
    }

    /// 8,000-char Japanese with multiple structures.
    static func medium() -> String {
        var s = "# 主見出し\n\n## サブ見出し\n\n"
        var n = 0
        while s.count < 6_500 {
            s += jpLine + "\n\n"
            if n % 5 == 2 {
                s += "- 箇条書き項目その1\n- 箇条書き項目その2\n- 箇条書き項目その3\n\n"
            }
            if n % 7 == 3 {
                s += "> 引用文。複数行にまたがる引用文の例。\n> 続きの行。\n\n"
            }
            n += 1
        }
        s += "```python\ndef compute(xs):\n    return sum(x * x for x in xs)\n\nprint(compute([1, 2, 3]))\n```\n\n"
        s += "```ruby\nputs [1, 2, 3].map { |x| x * 2 }\n```\n\n"
        return s
    }

    /// 20,000-char plain Japanese (cap value, no special structure).
    static func largePlain() -> String {
        var s = ""
        while s.count < 20_000 {
            s += jpLine + "\n\n"
        }
        return String(s.prefix(20_000))
    }

    /// 20,000-char with many math + code blocks interleaved.
    static func largeMathCode() -> String {
        var s = "# 見出し\n\n"
        var n = 0
        while s.count < 19_500 {
            s += jpLine + "\n\n"
            if n % 4 == 0 {
                s += "$$\nf(x) = \\sum_{i=0}^{n} a_i x^i\n$$\n\n"
            }
            if n % 5 == 0 {
                s += "```c\nint sum(int* a, int n) {\n    int s = 0;\n    for (int i = 0; i < n; ++i) s += a[i];\n    return s;\n}\n```\n\n"
            }
            if n % 6 == 0 {
                s += "$f(x)$ と $g(x)$ について、\\(h(x) = f(x) + g(x)\\) と定義する。\n\n"
            }
            n += 1
        }
        return String(s.prefix(20_000))
    }

    /// 1,500-char paragraph for LineBreakHints / softWrap measurements.
    static func longParagraph() -> String {
        let url = "https://example.com/some/very/long/path/to/a/file/with/dotted.identifier.chains/and/more/segments.txt"
        var s = ""
        while s.count < 1_500 {
            s += jpLine + " " + url + " " + enLine + " "
        }
        return String(s.prefix(1_500))
    }
}
