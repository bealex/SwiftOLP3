import Foundation
import SwiftParser
import SwiftSyntax

// Re-inserts the project's interior spaces on single-line collection *literals* (`[.foo]` → `[ .foo ]`),
// the one place swift-format's output diverges from the code style. Because it works on the parsed syntax
// tree, it touches only ArrayExpr / DictionaryExpr literal nodes — array TYPES (`[Int]`), subscripts
// (`arr[0]`), strings, and comments are different nodes and are left untouched.
@main
struct StyleRespace {
    static func main() throws {
        var paths = Array(CommandLine.arguments.dropFirst())
        let check = paths.contains("--check")
        paths.removeAll { $0.hasPrefix("--") }

        // No paths (or `-`): act as a stdin → stdout filter, so it can be piped after swift-format.
        if paths.isEmpty || paths == [ "-" ] {
            let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
            FileHandle.standardOutput.write(Data(respaced(input).utf8))
            return
        }

        var changed = 0
        for path in paths {
            let url: URL = .init(fileURLWithPath: path)
            guard let original = try? String(contentsOf: url, encoding: .utf8) else { continue }

            let result = respaced(original)
            guard result != original else { continue }

            changed += 1
            if check {
                print("✗ \(path)")
            } else {
                try result.write(to: url, atomically: true, encoding: .utf8)
            }
        }

        if check, changed > 0 { exit(1) }
    }

    private static func respaced(_ source: String) -> String {
        let tree = Parser.parse(source: source)
        let literals = CollectionLiteralSpacer().rewrite(tree)
        let expressions = ExpressionReturnNormalizer().rewrite(literals)
        let guards = GuardNormalizer().rewrite(expressions)
        let ternaries = TernaryNormalizer().rewrite(guards)
        let blanks = BlankLineNormalizer().rewrite(ternaries)
        let ifs = IfConditionNormalizer().rewrite(blanks)
        return MemberAttributeNormalizer().rewrite(ifs).description
    }
}

private final class CollectionLiteralSpacer: SyntaxRewriter {
    override func visit(_ node: ArrayExprSyntax) -> ExprSyntax {
        guard !isTypeConstructor(Syntax(node)) else { return super.visit(node) }
        guard let visited = super.visit(node).as(ArrayExprSyntax.self) else { return super.visit(node) }
        guard
            !visited.elements.isEmpty,
            isSingleLine(visited.leftSquare, visited.elements, visited.rightSquare)
        else { return ExprSyntax(visited) }

        var result = visited
        (result.leftSquare, result.rightSquare) = spacedBrackets(
            left: visited.leftSquare,
            firstLeading: visited.elements.first?.leadingTrivia ?? [],
            lastTrailing: visited.elements.last?.trailingTrivia ?? [],
            right: visited.rightSquare
        )
        return ExprSyntax(result)
    }

    override func visit(_ node: DictionaryExprSyntax) -> ExprSyntax {
        guard !isTypeConstructor(Syntax(node)) else { return super.visit(node) }
        guard let visited = super.visit(node).as(DictionaryExprSyntax.self) else { return super.visit(node) }
        guard
            case .elements(let elements) = visited.content,
            !elements.isEmpty,
            isSingleLine(visited.leftSquare, elements, visited.rightSquare)
        else { return ExprSyntax(visited) }

        var result = visited
        (result.leftSquare, result.rightSquare) = spacedBrackets(
            left: visited.leftSquare,
            firstLeading: elements.first?.leadingTrivia ?? [],
            lastTrailing: elements.last?.trailingTrivia ?? [],
            right: visited.rightSquare
        )
        return ExprSyntax(result)
    }

    // Only single-line literals get interior spaces; multi-line literals keep their own layout.
    private func isSingleLine(_ open: TokenSyntax, _ elements: some SyntaxProtocol, _ close: TokenSyntax) -> Bool {
        let interior = open.trailingTrivia.description + elements.description + close.leadingTrivia.description
        return !interior.contains("\n")
    }

    // Adds one interior space on each side, but only when that side has no whitespace yet. The gap after `[`
    // can live in the bracket's trailing trivia or the first element's leading trivia; the gap before `]` in
    // the last element's trailing trivia or the bracket's leading trivia — so both ends are checked. This
    // keeps the tool idempotent and never doubles an existing space.
    private func spacedBrackets(
        left: TokenSyntax,
        firstLeading: Trivia,
        lastTrailing: Trivia,
        right: TokenSyntax
    ) -> (TokenSyntax, TokenSyntax) {
        var left = left
        var right = right
        if !hasSpace(left.trailingTrivia), !hasSpace(firstLeading) {
            left.trailingTrivia = .space + left.trailingTrivia
        }
        if !hasSpace(lastTrailing), !hasSpace(right.leadingTrivia) {
            right.leadingTrivia = right.leadingTrivia + .space
        }
        return (left, right)
    }

    private func hasSpace(_ trivia: Trivia) -> Bool {
        trivia.contains { piece in
            return switch piece {
                case .spaces, .tabs: true
                default: false
            }
        }
    }

    // True when this bracket expression (or a collection literal enclosing it) is the called expression of a
    // function call — i.e. `[UInt8](repeating:…)`, `[Int]()`, `[[UInt8]](…)`, `[String: Int](…)`. There the
    // brackets are a *type*, not a value literal, and must stay tight. Climbs only through collection-literal
    // structure so a real literal in argument or member position (`[1, 2, 3].first`) is unaffected.
    private func isTypeConstructor(_ node: Syntax) -> Bool {
        var expression = node
        while true {
            if let call = expression.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == expression.id {
                return true
            }
            guard
                let parent = expression.parent,
                parent.is(ArrayExprSyntax.self) || parent.is(ArrayElementSyntax.self)
                    || parent.is(ArrayElementListSyntax.self) || parent.is(DictionaryExprSyntax.self)
                    || parent.is(DictionaryElementSyntax.self) || parent.is(DictionaryElementListSyntax.self)
            else { return false }

            expression = parent
        }
    }
}

// Normalises `guard` layout to the code style: a guard that fits in `lineLength` collapses to one line
// (`guard a, b else { … }`); otherwise it explodes — `guard` alone on its line, one condition per indented
// line, `else` on its own line — keeping swift-format's already-correct `else`/body. swift-format can't do
// this (it breaks by length, not per-condition), and the SwiftLint regex rule can only flag it, not fix it.
private final class GuardNormalizer: SyntaxRewriter {
    private let lineLength = 120

    override func visit(_ node: GuardStmtSyntax) -> StmtSyntax {
        let rewritten = super.visit(node)
        guard let node = rewritten.as(GuardStmtSyntax.self) else { return rewritten }

        // Bail only on things we can't restructure safely: a comment in a position that would be destroyed
        // (a condition's own leading line, or before `else`), or a single condition that is itself
        // multi-line. Trailing line comments on a condition are preserved (see `relaid`).
        let conditionTexts = node.conditions.map { $0.condition.trimmedDescription }
        guard
            !node.conditions.isEmpty,
            !hasLeadingComment(node),
            conditionTexts.allSatisfy({ !$0.contains("\n") })
        else { return StmtSyntax(node) }

        let indent = leadingIndentation(node)
        let bodyText = node.body.trimmedDescription

        // A trailing line comment can't share a one-line guard (it would swallow the rest), so only collapse
        // when there are no condition comments at all.
        if !bodyText.contains("\n"), !hasTrailingComment(node) {
            let oneLine = indent + "guard " + conditionTexts.joined(separator: ", ") + " else " + bodyText
            if oneLine.count <= lineLength { return StmtSyntax(relaid(node, indent: indent, multiline: false)) }
        }

        return StmtSyntax(relaid(node, indent: indent, multiline: true))
    }

    // Rebuilds the guard keyword + condition list (and the `else` keyword's leading break) for either layout.
    // The `else` keyword's trailing trivia and the body node are left exactly as swift-format produced them.
    private func relaid(_ node: GuardStmtSyntax, indent: String, multiline: Bool) -> GuardStmtSyntax {
        var node = node
        let elementLeading: Trivia = multiline ? .newline + .spaces(indent.count + 4) : []
        let commaTrailing: Trivia = multiline ? [] : .space

        var elements: [ConditionElementSyntax] = []
        for element in node.conditions {
            var element = element
            // Preserve a trailing line/block comment (it lives on the condition or its comma) — trimming
            // would otherwise drop it.
            let comment =
                commentPieces(element.condition.trailingTrivia)
                + commentPieces(element.trailingComma?.trailingTrivia ?? [])
            element.condition = element.condition.trimmed
            element.leadingTrivia = elementLeading
            if element.trailingComma != nil {
                let trailing: Trivia = comment.isEmpty ? commaTrailing : Trivia(pieces: [ .spaces(2) ] + comment)
                element.trailingComma = .commaToken(trailingTrivia: trailing)
            } else if !comment.isEmpty {
                element.condition = element.condition.with(\.trailingTrivia, Trivia(pieces: [ .spaces(2) ] + comment))
            }
            elements.append(element)
        }

        node.guardKeyword.trailingTrivia = multiline ? [] : .space
        node.conditions = ConditionElementListSyntax(elements)
        node.elseKeyword.leadingTrivia = multiline ? .newline + .spaces(indent.count) : .space
        return node
    }

    // The horizontal whitespace at the start of the guard's own line (assumes space indentation).
    private func leadingIndentation(_ node: some SyntaxProtocol) -> String {
        var indent = ""
        for piece in node.leadingTrivia.reversed() {
            switch piece {
                case .spaces(let count): indent = String(repeating: " ", count: count) + indent
                case .tabs(let count): indent = String(repeating: "\t", count: count) + indent
                default: return indent
            }
        }
        return indent
    }

    // A comment we would destroy by re-laying the conditions: on a condition's own leading line, or in the
    // gap before `else`. (Trailing comments are preserved, so they don't count here.)
    private func hasLeadingComment(_ node: GuardStmtSyntax) -> Bool {
        node.conditions.contains { $0.leadingTrivia.contains(where: { isComment($0) }) }
            || node.elseKeyword.leadingTrivia.contains(where: { isComment($0) })
    }

    private func hasTrailingComment(_ node: GuardStmtSyntax) -> Bool {
        node.conditions.contains { element in
            !commentPieces(element.condition.trailingTrivia).isEmpty
                || !commentPieces(element.trailingComma?.trailingTrivia ?? []).isEmpty
        }
    }

    private func commentPieces(_ trivia: Trivia) -> [TriviaPiece] {
        trivia.filter { isComment($0) }
    }

    private func isComment(_ piece: TriviaPiece) -> Bool {
        return switch piece {
            case .lineComment, .blockComment, .docLineComment, .docBlockComment: true
            default: false
        }
    }
}

// On a multi-line ternary (`?` / `:` each on their own line), keeps the condition on the line it starts —
// swift-format breaks after the `=`/`return` and drops the condition onto its own line; this pulls it back
// up so the layout reads `let x = cond` / `?` / `:` with the operators indented under it. swift-format
// already indents the `?` and `:`; only the leading break before the condition is removed.
//
// `Parser.parse` leaves operators unfolded, so a ternary is a SequenceExpr whose middle element is an
// UnresolvedTernaryExpr (the `? then :`) — not a folded TernaryExpr. We work on that shape.
private final class TernaryNormalizer: SyntaxRewriter {
    override func visit(_ node: SequenceExprSyntax) -> ExprSyntax {
        let rewritten = super.visit(node)
        guard let node = rewritten.as(SequenceExprSyntax.self) else { return rewritten }

        let elements = Array(node.elements)
        guard
            let ternaryIndex = elements.firstIndex(where: { $0.is(UnresolvedTernaryExprSyntax.self) }),
            let ternary = elements[ternaryIndex].as(UnresolvedTernaryExprSyntax.self),
            containsNewline(ternary.questionMark.leadingTrivia) || containsNewline(ternary.colon.leadingTrivia)
        else { return ExprSyntax(node) }

        // Pull up the ternary's condition — the element immediately before the `?` — not elements[0], which
        // in an assignment expression (`self.x = cond ? …`) is the left-hand side. Removing its leading break
        // would swallow a statement separator.
        let conditionIndex = ternaryIndex - 1
        guard
            conditionIndex >= 0,
            containsNewline(elements[conditionIndex].leadingTrivia)
        else {
            return ExprSyntax(node)
        }

        // Only safe when the break is a continuation of an RHS: the whole sequence is a `let x = …` /
        // `return …` value (condition is the first element), or an assignment `=` sits right before it.
        let safe =
            conditionIndex == 0
            ? node.parent?.is(InitializerClauseSyntax.self) == true || node.parent?.is(ReturnStmtSyntax.self) == true
            : elements[conditionIndex - 1].is(AssignmentExprSyntax.self)
        guard safe else { return ExprSyntax(node) }

        var newElements = elements
        newElements[conditionIndex].leadingTrivia = .space
        var result = node
        result.elements = ExprListSyntax(newElements)
        return ExprSyntax(result)
    }

    private func containsNewline(_ trivia: Trivia) -> Bool {
        trivia.contains { piece in
            return switch piece {
                case .newlines, .carriageReturns, .carriageReturnLineFeeds: true
                default: false
            }
        }
    }
}

// Enforces two blank-line rules inside braced bodies / closures (not top level), neither of which
// swift-format can express:
//   • a nested (local) function is surrounded by a blank line;
//   • a `guard` is followed by a blank line, but a run of consecutive guards stays together with the single
//     blank line only after the last one.
// It only adjusts the blank count on a statement that already begins its own line, and preserves any
// comments and indentation in the leading trivia.
private final class BlankLineNormalizer: SyntaxRewriter {
    override func visit(_ node: CodeBlockItemListSyntax) -> CodeBlockItemListSyntax {
        let node = super.visit(node)

        guard node.parent?.is(SourceFileSyntax.self) != true else { return node }

        var items = Array(node)
        guard items.count > 1 else { return node }

        for index in 1 ..< items.count {
            let previous = items[index - 1].item
            let current = items[index].item
            let previousGuard = previous.is(GuardStmtSyntax.self)
            let currentGuard = current.is(GuardStmtSyntax.self)

            var blanks: Int?
            if previousGuard { blanks = currentGuard ? 0 : 1 }
            if current.is(FunctionDeclSyntax.self) || previous.is(FunctionDeclSyntax.self) { blanks = 1 }

            if let blanks { items[index] = withLeadingBlanks(items[index], blanks) }
        }

        return CodeBlockItemListSyntax(items)
    }

    // A type's members: surround each function-like member (method / init / deinit / subscript) with a blank
    // line — swift-format never adds blank lines between members. Adjacent properties stay grouped.
    override func visit(_ node: MemberBlockItemListSyntax) -> MemberBlockItemListSyntax {
        let node = super.visit(node)

        var items = Array(node)
        guard items.count > 1 else { return node }

        for index in 1 ..< items.count where isMethodLike(items[index - 1].decl) || isMethodLike(items[index].decl) {
            items[index] = withLeadingBlanks(items[index], 1)
        }

        return MemberBlockItemListSyntax(items)
    }

    private func isMethodLike(_ decl: DeclSyntax) -> Bool {
        decl.is(FunctionDeclSyntax.self) || decl.is(InitializerDeclSyntax.self)
            || decl.is(DeinitializerDeclSyntax.self) || decl.is(SubscriptDeclSyntax.self)
    }

    private func withLeadingBlanks<Item: SyntaxProtocol>(_ item: Item, _ blanks: Int) -> Item {
        let pieces = Array(item.leadingTrivia)
        var newlineRun = 0
        while newlineRun < pieces.count, isNewline(pieces[newlineRun]) { newlineRun += 1 }

        guard newlineRun > 0 else { return item }

        return item.with(\.leadingTrivia, Trivia(pieces: [ .newlines(blanks + 1) ] + pieces[newlineRun...]))
    }

    private func isNewline(_ piece: TriviaPiece) -> Bool {
        return switch piece {
            case .newlines, .carriageReturns, .carriageReturnLineFeeds: true
            default: false
        }
    }
}

// Turns a statement-form `switch` / `if` whose every branch is a single `return <expr>` into the
// expression form `return switch … { case …: <expr> }` (codestyle: prefer expression `if`/`switch`).
// Only fires when every branch is exactly one `return` with a value; `if` must be exhaustive (have a final
// `else`). swift-format can't do this and a SwiftLint regex can't tell whether every branch returns.
private final class ExpressionReturnNormalizer: SyntaxRewriter {
    override func visit(_ node: CodeBlockItemSyntax) -> CodeBlockItemSyntax {
        let node = super.visit(node)

        // A statement-position `switch` / `if` is an ExpressionStmt wrapping the expression.
        guard
            case .stmt(let statement) = node.item,
            let expr = statement.as(ExpressionStmtSyntax.self)?.expression
        else { return node }

        let converted: ExprSyntax?
        if let switchExpr = expr.as(SwitchExprSyntax.self) {
            converted = expressionSwitch(switchExpr).map(ExprSyntax.init)
        } else if let ifExpr = expr.as(IfExprSyntax.self) {
            converted = expressionIf(ifExpr).map(ExprSyntax.init)
        } else {
            converted = nil
        }

        guard let body = converted else { return node }

        var returnKeyword: TokenSyntax = .keyword(.return)
        returnKeyword.leadingTrivia = expr.leadingTrivia
        returnKeyword.trailingTrivia = .space
        let returnStmt = ReturnStmtSyntax(returnKeyword: returnKeyword, expression: body.with(\.leadingTrivia, []))

        var result = node
        result.item = .stmt(StmtSyntax(returnStmt))
        return result
    }

    private func expressionSwitch(_ node: SwitchExprSyntax) -> SwitchExprSyntax? {
        guard !node.cases.isEmpty else { return nil }

        var cases: [SwitchCaseListSyntax.Element] = []
        for element in node.cases {
            guard
                let switchCase = element.as(SwitchCaseSyntax.self),
                let value = singleReturnedValue(switchCase.statements)
            else { return nil }

            cases.append(.init(switchCase.with(\.statements, asExpression(value))))
        }
        return node.with(\.cases, SwitchCaseListSyntax(cases))
    }

    private func expressionIf(_ node: IfExprSyntax) -> IfExprSyntax? {
        guard
            let thenValue = singleReturnedValue(node.body.statements),
            let elseBody = node.elseBody
        else { return nil }

        let newElse: IfExprSyntax.ElseBody
        switch elseBody {
            case .codeBlock(let block):
                guard let value = singleReturnedValue(block.statements) else { return nil }

                newElse = .codeBlock(block.with(\.statements, asExpression(value)))
            case .ifExpr(let elseIf):
                guard let converted = expressionIf(elseIf) else { return nil }

                newElse = .ifExpr(converted)
        }

        return
            node
            .with(\.body, node.body.with(\.statements, asExpression(thenValue)))
            .with(\.elseBody, newElse)
    }

    // The single `return <expr>`'s value, carrying the `return` keyword's leading trivia (its indentation).
    private func singleReturnedValue(_ statements: CodeBlockItemListSyntax) -> ExprSyntax? {
        guard
            statements.count == 1,
            let only = statements.first,
            let returnStmt = only.item.as(ReturnStmtSyntax.self),
            let value = returnStmt.expression
        else { return nil }

        return value.with(\.leadingTrivia, returnStmt.returnKeyword.leadingTrivia)
    }

    private func asExpression(_ value: ExprSyntax) -> CodeBlockItemListSyntax {
        CodeBlockItemListSyntax([ CodeBlockItemSyntax(item: .expr(value)) ])
    }
}

// Puts the attributes / property wrappers of a *member* property on their own line, above the declaration
// (`@ObservationIgnored let x` → `@ObservationIgnored` ⏎ `let x`). swift-format keeps them inline and has no
// option otherwise. Multiple attributes stay as swift-format laid them out (one line, or wrapped if long);
// only the break between the attribute list and the `let`/`var` (or its access modifier) is inserted. Local
// variables inside function/closure bodies keep their attributes inline, per the code style.
private final class MemberAttributeNormalizer: SyntaxRewriter {
    override func visit(_ node: VariableDeclSyntax) -> DeclSyntax {
        let isMember = node.parent?.is(MemberBlockItemSyntax.self) == true
        guard let node = super.visit(node).as(VariableDeclSyntax.self) else { return super.visit(node) }
        guard isMember, let lastAttribute = node.attributes.last else { return DeclSyntax(node) }

        let indent = leadingIndentation(node)
        let breakTrivia: Trivia = .newline + .spaces(indent.count)

        // Skip if the break is already there (idempotent).
        guard !lastAttribute.trailingTrivia.contains(where: \.isNewline) else { return DeclSyntax(node) }

        var result = node
        result.attributes = node.attributes.with(\.trailingTrivia, breakTrivia)
        if result.modifiers.isEmpty {
            result.bindingSpecifier.leadingTrivia = []
        } else {
            result.modifiers = result.modifiers.with(\.leadingTrivia, [])
        }
        return DeclSyntax(result)
    }

    private func leadingIndentation(_ node: some SyntaxProtocol) -> String {
        var indent = ""
        for piece in node.leadingTrivia.reversed() {
            switch piece {
                case .spaces(let count): indent = String(repeating: " ", count: count) + indent
                case .tabs(let count): indent = String(repeating: "\t", count: count) + indent
                default: return indent
            }
        }
        return indent
    }
}

// Lays out a multi-line `if` statement's wrapped conditions the project way: continuation conditions are
// double-indented (two levels below the `if` line) and the opening `{` stays at the end of the last
// condition line — instead of swift-format's single-indent + brace on its own line. Only standalone,
// line-starting `if` statements with already-wrapped conditions are touched (not `else if`, not the
// `return if` expression form, not single-line ifs).
private final class IfConditionNormalizer: SyntaxRewriter {
    // `if` (including `else if`, reached by recursion, and the `return if` / `let x = if` expression forms):
    // when the condition wrapped — the tell is swift-format putting the body's `{` on its own line — push
    // the continuation lines one indent deeper and bring the `{` up onto the last condition line.
    override func visit(_ node: IfExprSyntax) -> ExprSyntax {
        let rewritten = super.visit(node)
        guard let node = rewritten.as(IfExprSyntax.self) else { return rewritten }
        guard let (conditions, body) = relaid(node.conditions, node.body) else { return ExprSyntax(node) }

        return ExprSyntax(node.with(\.conditions, conditions).with(\.body, body))
    }

    override func visit(_ node: WhileStmtSyntax) -> StmtSyntax {
        let rewritten = super.visit(node)
        guard let node = rewritten.as(WhileStmtSyntax.self) else { return rewritten }
        guard let (conditions, body) = relaid(node.conditions, node.body) else { return StmtSyntax(node) }

        return StmtSyntax(node.with(\.conditions, conditions).with(\.body, body))
    }

    // `repeat { … } while <condition>` has no brace after the condition, so only the continuation indent
    // applies when the trailing condition wraps. `repeat` is always line-starting, so we can bump the
    // single-indented continuation to an absolute double indent (idempotent — there is no brace move to gate
    // re-application as there is for if / while).
    override func visit(_ node: RepeatStmtSyntax) -> StmtSyntax {
        let rewritten = super.visit(node)
        guard let node = rewritten.as(RepeatStmtSyntax.self) else { return rewritten }

        let base = indentWidth(node.leadingTrivia)
        guard
            node.condition.description.contains("\n"),
            let indented = LineReindenter(from: base + 4, to: base + 8)
                .rewrite(node.condition).as(ExprSyntax.self)
        else { return StmtSyntax(node) }

        return StmtSyntax(node.with(\.condition, indented))
    }

    private func indentWidth(_ trivia: Trivia) -> Int {
        var width = 0
        for piece in trivia.reversed() {
            switch piece {
                case .spaces(let count): width += count
                case .tabs(let count): width += count
                default: return width
            }
        }
        return width
    }

    // Double-indents the wrapped condition lines and moves `{` onto the last one. Returns nil (no change)
    // when the conditions are single-line — swift-format keeps `{` inline then.
    private func relaid(
        _ conditions: ConditionElementListSyntax,
        _ body: CodeBlockSyntax
    ) -> (ConditionElementListSyntax, CodeBlockSyntax)? {
        guard
            body.leftBrace.leadingTrivia.contains(where: \.isNewline),
            let indented = ContinuationIndenter(extraSpaces: 4)
                .rewrite(conditions).as(ConditionElementListSyntax.self)
        else { return nil }

        var elements = Array(indented)
        if !elements.isEmpty {
            // Clear the last condition's trailing trivia so the single space comes only from the brace below
            // (keeps the tool idempotent across re-parses).
            elements[elements.count - 1] = elements[elements.count - 1].with(\.trailingTrivia, [])
        }

        var body = body
        body.leftBrace.leadingTrivia = .space
        return (ConditionElementListSyntax(elements), body)
    }
}

// Re-indents every continuation line that sits at exactly `from` spaces to `to` spaces (lines a token starts,
// after a newline in its leading trivia). Idempotent — a line already at `to` is left alone.
private final class LineReindenter: SyntaxRewriter {
    private let from: Int
    private let to: Int

    init(from: Int, to: Int) {
        self.from = from
        self.to = to
    }

    override func visit(_ token: TokenSyntax) -> TokenSyntax {
        guard token.leadingTrivia.contains(where: \.isNewline) else { return token }

        var pieces: [TriviaPiece] = []
        var afterNewline = false
        for piece in token.leadingTrivia {
            switch piece {
                case .newlines, .carriageReturns, .carriageReturnLineFeeds:
                    pieces.append(piece)
                    afterNewline = true
                case .spaces(let count) where afterNewline && count == from:
                    pieces.append(.spaces(to))
                    afterNewline = false
                default:
                    pieces.append(piece)
                    afterNewline = false
            }
        }
        return token.with(\.leadingTrivia, Trivia(pieces: pieces))
    }
}

// Adds `extraSpaces` to the indentation of every line a token starts (the spaces in its leading trivia right
// after a newline), shifting a wrapped construct one indent level deeper without touching single-line trivia.
private final class ContinuationIndenter: SyntaxRewriter {
    private let extraSpaces: Int

    init(extraSpaces: Int) {
        self.extraSpaces = extraSpaces
    }

    override func visit(_ token: TokenSyntax) -> TokenSyntax {
        guard token.leadingTrivia.contains(where: \.isNewline) else { return token }

        var pieces: [TriviaPiece] = []
        var afterNewline = false
        for piece in token.leadingTrivia {
            switch piece {
                case .newlines, .carriageReturns, .carriageReturnLineFeeds:
                    pieces.append(piece)
                    afterNewline = true
                case .spaces(let count) where afterNewline:
                    pieces.append(.spaces(count + extraSpaces))
                    afterNewline = false
                default:
                    if afterNewline { pieces.append(.spaces(extraSpaces)) }
                    pieces.append(piece)
                    afterNewline = false
            }
        }
        return token.with(\.leadingTrivia, Trivia(pieces: pieces))
    }
}

extension TriviaPiece {
    fileprivate var isNewline: Bool {
        return switch self {
            case .newlines, .carriageReturns, .carriageReturnLineFeeds: true
            default: false
        }
    }
}
