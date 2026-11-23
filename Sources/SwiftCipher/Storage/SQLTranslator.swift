import Foundation
import SwiftData
import SQLiteDB
import SQLCipher

/// SQL text with the values bound to its `?` placeholders, in order.
struct SQL {
    var text: String
    var bindings: [Binding?]

    init(_ text: String, _ bindings: [Binding?] = []) {
        self.text = text
        self.bindings = bindings
    }

    static func + (lhs: SQL, rhs: SQL) -> SQL {
        SQL(lhs.text + rhs.text, lhs.bindings + rhs.bindings)
    }

    static func + (lhs: SQL, rhs: String) -> SQL { lhs + SQL(rhs) }
    static func + (lhs: String, rhs: SQL) -> SQL { SQL(lhs) + rhs }
}

/// A predicate or sort that has no exact SQL equivalent. The store then lets SwiftData
/// evaluate it in memory, or reports `unsupportedQuery` where SwiftData cannot.
struct Untranslatable: Error {
    let reason: String
}

/// The SQL meaning of a predicate sub-expression.
enum Fragment {
    /// A value. `kind` is the column kind when the value comes straight from a column,
    /// so constants compared against it can be encoded the same way.
    case scalar(SQL, ColumnKind?)
    /// A Swift constant not yet encoded; encoding depends on what it is compared with.
    case constant(Any?)
    /// A model. `key` evaluates to its primary key (NULL when absent); `alias` is set when
    /// its table is already in the FROM clause.
    case row(entity: String, key: SQL, alias: String?)
    /// A to-many relationship of the row whose primary key is `owner`.
    case toMany(owner: SQL, entity: String, relationship: String)
}

/// Builds a SELECT for one entity from a `FetchDescriptor`.
final class SQLQueryBuilder {
    let tables: [String: EntityTable]
    private var aliasCount = 0
    /// LEFT JOINs per subquery scope; the first scope is the outer query.
    private var scopes: [[(key: String, clause: String, alias: String)]] = [[]]
    var variables: [PredicateExpressions.VariableID: Fragment] = [:]

    init(tables: [String: EntityTable]) {
        self.tables = tables
    }

    func newAlias() -> String {
        aliasCount += 1
        return "t\(aliasCount)"
    }

    func table(_ entity: String) throws -> EntityTable {
        guard let table = tables[entity] else { throw Untranslatable(reason: "\(entity) is not in this store") }
        return table
    }

    /// Runs `body` in a nested scope and returns the joins it needed.
    func withScope<R>(_ body: () throws -> R) rethrows -> (R, String) {
        scopes.append([])
        defer { scopes.removeLast() }
        let result = try body()
        return (result, scopes.last!.map(\.clause).joined())
    }

    /// The alias of a model's table, joining it on demand.
    func alias(for entity: String, key: SQL, alias: String?) -> String {
        if let alias { return alias }
        let joinKey = entity + "|" + key.text
        for scope in scopes.reversed() {
            if let existing = scope.first(where: { $0.key == joinKey }) { return existing.alias }
        }
        let alias = newAlias()
        let clause = " LEFT JOIN \(q(entity)) AS \(alias) ON \(alias).\(q(EntityTable.primaryKey)) = \(key.text)"
        scopes[scopes.count - 1].append((joinKey, clause, alias))
        return alias
    }

    var outerJoins: String { scopes[0].map(\.clause).joined() }

    func translate(_ expression: Any) throws -> Fragment {
        guard let expression = expression as? any SQLTranslatable else {
            throw Untranslatable(reason: "\(type(of: expression))")
        }
        return try expression.fragment(in: self)
    }

    /// A fragment as an SQL value. Constants are encoded to match `kind`.
    func value(_ fragment: Fragment, as kind: ColumnKind? = nil) throws -> SQL {
        switch fragment {
        case .scalar(let sql, _): return sql
        case .row(_, let key, _): return key
        case .constant(let value): return try constant(value, as: kind)
        case .toMany: throw Untranslatable(reason: "to-many relationship used as a value")
        }
    }

    func boolean(_ expression: Any) throws -> SQL {
        try value(translate(expression))
    }

    func kind(of fragment: Fragment) -> ColumnKind? {
        switch fragment {
        case .scalar(_, let kind): kind
        case .row: .text
        default: nil
        }
    }

    // MARK: Constants

    func constant(_ value: Any?, as kind: ColumnKind?) throws -> SQL {
        guard let value = flattenOptional(value) else { return SQL("NULL") }
        if kind == .json {
            guard let encodable = value as? any Encodable else { throw Untranslatable(reason: "\(type(of: value)) is not Encodable") }
            let data = try JSONEncoder().encode(encodable)
            let object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            let text = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
            return SQL("?", [String(decoding: text, as: UTF8.self)])
        }
        return SQL("?", [try binding(for: value)])
    }

    private func binding(for value: Any) throws -> Binding {
        switch value {
        case let v as Bool: return Int64(v ? 1 : 0)
        case let v as String: return v
        case let v as Date: return v.timeIntervalSinceReferenceDate
        case let v as UUID: return v.uuidString
        case let v as URL: return v.absoluteString
        case let v as Data: return Blob(bytes: Array(v))
        case let v as any BinaryInteger: return Int64(v)
        case let v as Double: return v
        case let v as Float: return Double(v)
        case let v as PersistentIdentifier: return try primaryKey(of: v)
        case let v as any PersistentModel: return try primaryKey(of: v.persistentModelID)
        default: throw Untranslatable(reason: "constant of type \(type(of: value))")
        }
    }

    private func primaryKey(of identifier: PersistentIdentifier) throws -> String {
        let data = try JSONEncoder().encode(identifier)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let key = (object?["implementation"] as? [String: Any])?["primaryKey"] as? String else {
            throw Untranslatable(reason: "identifier without primary key")
        }
        return key
    }
}

func flattenOptional(_ value: Any?) -> Any? {
    guard let value else { return nil }
    if let optional = value as? any OptionalValue { return flattenOptional(optional.wrappedValue) }
    return value
}

protocol OptionalValue { var wrappedValue: Any? { get } }
extension Optional: OptionalValue {
    var wrappedValue: Any? { self.map { $0 } }
}

// MARK: - Key paths

/// Maps a model's key paths to schema property names, read from the `@Model`-generated
/// `schemaMetadata`. Its fields are not public API, so they are read by reflection.
enum PropertyNames {
    nonisolated(unsafe) private static var cache: [ObjectIdentifier: [AnyKeyPath: String]] = [:]
    private static let lock = NSLock()

    static func name(of keyPath: AnyKeyPath) -> String? {
        guard let model = type(of: keyPath).rootType as? any PersistentModel.Type else { return nil }
        return lock.withLock {
            let id = ObjectIdentifier(model)
            if cache[id] == nil {
                var names: [AnyKeyPath: String] = [:]
                for metadata in model.schemaMetadata {
                    let mirror = Mirror(reflecting: metadata)
                    let name = mirror.children.first { $0.label == "name" }?.value as? String
                    let path = mirror.children.first { $0.label == "keypath" }?.value as? AnyKeyPath
                    if let name, let path { names[path] = name }
                }
                cache[id] = names
            }
            return cache[id]?[keyPath]
        }
    }
}

// MARK: - Expressions

protocol SQLTranslatable {
    func fragment(in builder: SQLQueryBuilder) throws -> Fragment
}

extension PredicateExpressions.Variable: SQLTranslatable {
    func fragment(in builder: SQLQueryBuilder) throws -> Fragment {
        guard let bound = builder.variables[key] else { throw Untranslatable(reason: "unbound variable") }
        return bound
    }
}

extension PredicateExpressions.Value: SQLTranslatable {
    func fragment(in builder: SQLQueryBuilder) throws -> Fragment { .constant(value) }
}

extension PredicateExpressions.NilLiteral: SQLTranslatable {
    func fragment(in builder: SQLQueryBuilder) throws -> Fragment { .constant(nil) }
}

extension PredicateExpressions.KeyPath: SQLTranslatable {
    func fragment(in builder: SQLQueryBuilder) throws -> Fragment {
        guard case let .row(entity, key, alias) = try builder.translate(root) else {
            throw Untranslatable(reason: "key path on a non-model value")
        }
        guard let name = PropertyNames.name(of: keyPath) else {
            // `persistentModelID` is not a schema property; it maps to the primary key.
            if "\(keyPath)".hasSuffix(".persistentModelID") { return .scalar(key, .text) }
            throw Untranslatable(reason: "key path \(keyPath)")
        }
        let table = try builder.table(entity)
        if let attribute = table.attributes.first(where: { $0.name == name }) {
            let alias = builder.alias(for: entity, key: key, alias: alias)
            return .scalar(SQL("\(alias).\(q(name))"), attribute.kind)
        }
        if let destination = table.toOne[name] {
            let alias = builder.alias(for: entity, key: key, alias: alias)
            return .row(entity: destination, key: SQL("\(alias).\(q(name))"), alias: nil)
        }
        if table.derivedToMany[name] != nil || table.joinTables.contains(where: { $0.relationship == name }) {
            return .toMany(owner: key, entity: entity, relationship: name)
        }
        throw Untranslatable(reason: "\(entity).\(name) is not stored")
    }
}

/// `a == b` with Swift semantics: `nil == nil` is true, never NULL.
private func equality(_ lhs: Any, _ rhs: Any, negated: Bool, in builder: SQLQueryBuilder) throws -> Fragment {
    let l = try builder.translate(lhs), r = try builder.translate(rhs)
    let kind = builder.kind(of: l) ?? builder.kind(of: r)
    if kind == .blob { throw Untranslatable(reason: "comparing Data") }
    let sql = try builder.value(l, as: kind) + (negated ? " IS NOT " : " IS ") + builder.value(r, as: kind)
    return .scalar("(" + sql + ")", .bool)
}

extension PredicateExpressions.Equal: SQLTranslatable {
    func fragment(in builder: SQLQueryBuilder) throws -> Fragment { try equality(lhs, rhs, negated: false, in: builder) }
}

extension PredicateExpressions.NotEqual: SQLTranslatable {
    func fragment(in builder: SQLQueryBuilder) throws -> Fragment { try equality(lhs, rhs, negated: true, in: builder) }
}

extension PredicateExpressions.Comparison: SQLTranslatable {
    func fragment(in builder: SQLQueryBuilder) throws -> Fragment {
        let l = try builder.translate(lhs), r = try builder.translate(rhs)
        let kind = builder.kind(of: l) ?? builder.kind(of: r)
        guard let kind, [.integer, .real, .text, .bool].contains(kind) else {
            throw Untranslatable(reason: "ordering on \(String(describing: kind)) values")
        }
        let symbol = switch op {
        case .lessThan: "<"
        case .lessThanOrEqual: "<="
        case .greaterThan: ">"
        case .greaterThanOrEqual: ">="
        @unknown default: throw Untranslatable(reason: "comparison \(op)")
        }
        return try .scalar("(" + builder.value(l, as: kind) + " \(symbol) " + builder.value(r, as: kind) + ")", .bool)
    }
}

extension PredicateExpressions.Conjunction: SQLTranslatable {
    func fragment(in builder: SQLQueryBuilder) throws -> Fragment {
        try .scalar("(" + builder.boolean(lhs) + " AND " + builder.boolean(rhs) + ")", .bool)
    }
}

extension PredicateExpressions.Disjunction: SQLTranslatable {
    func fragment(in builder: SQLQueryBuilder) throws -> Fragment {
        try .scalar("(" + builder.boolean(lhs) + " OR " + builder.boolean(rhs) + ")", .bool)
    }
}

extension PredicateExpressions.Negation: SQLTranslatable {
    func fragment(in builder: SQLQueryBuilder) throws -> Fragment {
        try .scalar("(NOT " + builder.boolean(wrapped) + ")", .bool)
    }
}

extension PredicateExpressions.NilCoalesce: SQLTranslatable {
    func fragment(in builder: SQLQueryBuilder) throws -> Fragment {
        let l = try builder.translate(lhs), r = try builder.translate(rhs)
        let kind = builder.kind(of: l) ?? builder.kind(of: r)
        return try .scalar("COALESCE(" + builder.value(l, as: kind) + ", " + builder.value(r, as: kind) + ")", kind)
    }
}

extension PredicateExpressions.ForcedUnwrap: SQLTranslatable {
    func fragment(in builder: SQLQueryBuilder) throws -> Fragment { try builder.translate(inner) }
}

extension PredicateExpressions.OptionalFlatMap: SQLTranslatable {
    func fragment(in builder: SQLQueryBuilder) throws -> Fragment {
        let input = try builder.translate(wrapped)
        builder.variables[variable.key] = input
        defer { builder.variables[variable.key] = nil }
        let output = try builder.translate(transform)
        if case .row = output { return output }
        let test = try builder.value(input)
        // nil in, nil out, even if the transform would produce a value from NULL.
        return try .scalar("(CASE WHEN " + test + " IS NULL THEN NULL ELSE " + builder.value(output) + " END)", builder.kind(of: output))
    }
}

extension PredicateExpressions.Conditional: SQLTranslatable {
    func fragment(in builder: SQLQueryBuilder) throws -> Fragment {
        let a = try builder.translate(trueBranch), b = try builder.translate(falseBranch)
        let kind = builder.kind(of: a) ?? builder.kind(of: b)
        return try .scalar("(CASE WHEN " + builder.boolean(test) + " THEN " + builder.value(a, as: kind) + " ELSE " + builder.value(b, as: kind) + " END)", kind)
    }
}

extension PredicateExpressions.SequenceContains: SQLTranslatable {
    func fragment(in builder: SQLQueryBuilder) throws -> Fragment {
        let element = try builder.translate(self.element)
        let kind = builder.kind(of: element)
        guard case .constant(let collection) = try builder.translate(sequence),
              let values = flattenOptional(collection) as? any Sequence else {
            throw Untranslatable(reason: "contains on a non-constant sequence")
        }
        let items = try values.map { try builder.constant($0, as: kind) }
        guard !items.isEmpty else { return .scalar(SQL("0"), .bool) }
        let list = items.dropFirst().reduce(items[0]) { $0 + ", " + $1 }
        return try .scalar("(" + builder.value(element, as: kind) + " IN (" + list + "))", .bool)
    }
}

extension PredicateExpressions.SequenceContainsWhere: SQLTranslatable {
    func fragment(in builder: SQLQueryBuilder) throws -> Fragment {
        guard case let .toMany(owner, entity, relationship) = try builder.translate(sequence) else {
            throw Untranslatable(reason: "contains(where:) on a non-relationship")
        }
        let table = try builder.table(entity)
        let alias = builder.newAlias()
        let from: String, link: SQL
        if let derived = table.derivedToMany[relationship] {
            from = "\(q(derived.destination)) AS \(alias)"
            link = "\(alias).\(q(derived.inverse)) = " + owner
            builder.variables[variable.key] = .row(entity: derived.destination, key: SQL("\(alias).\(q(EntityTable.primaryKey))"), alias: alias)
        } else if let join = table.joinTables.first(where: { $0.relationship == relationship }) {
            let j = builder.newAlias()
            from = "\(q(join.table)) AS \(j) JOIN \(q(join.destination)) AS \(alias) ON \(alias).\(q(EntityTable.primaryKey)) = \(j).target"
            link = "\(j).owner = " + owner
            builder.variables[variable.key] = .row(entity: join.destination, key: SQL("\(alias).\(q(EntityTable.primaryKey))"), alias: alias)
        } else {
            throw Untranslatable(reason: "\(entity).\(relationship) is not a to-many relationship")
        }
        defer { builder.variables[variable.key] = nil }
        let (condition, joins) = try builder.withScope { try builder.boolean(test) }
        return .scalar("EXISTS (SELECT 1 FROM \(from)\(joins) WHERE " + link + " AND " + condition + ")", .bool)
    }
}

/// String operations run as SQL functions that call the same Swift methods, so results
/// match in-memory evaluation exactly.
private func stringCall(_ function: String, _ lhs: Any, _ rhs: Any, in builder: SQLQueryBuilder) throws -> Fragment {
    let l = try builder.translate(lhs), r = try builder.translate(rhs)
    for side in [l, r] {
        if let kind = builder.kind(of: side), kind != .text { throw Untranslatable(reason: "\(function) on \(kind)") }
        if case .constant(let value) = side, !(flattenOptional(value) is String) { throw Untranslatable(reason: "\(function) on non-string") }
    }
    return try .scalar("\(function)(" + builder.value(l, as: .text) + ", " + builder.value(r, as: .text) + ")", .bool)
}

extension PredicateExpressions.CollectionContainsCollection: SQLTranslatable {
    func fragment(in builder: SQLQueryBuilder) throws -> Fragment { try stringCall("sc_contains", base, other, in: builder) }
}

extension PredicateExpressions.StringLocalizedStandardContains: SQLTranslatable {
    func fragment(in builder: SQLQueryBuilder) throws -> Fragment { try stringCall("sc_localized_contains", root, other, in: builder) }
}

extension PredicateExpressions.SequenceStartsWith: SQLTranslatable {
    func fragment(in builder: SQLQueryBuilder) throws -> Fragment { try stringCall("sc_starts_with", base, prefix, in: builder) }
}

// MARK: - Query

extension SQLQueryBuilder {
    /// FROM / WHERE / ORDER BY for a descriptor, with the root table aliased `t0`.
    /// Throws `Untranslatable` naming the first part that has no SQL equivalent.
    func clauses<T: PersistentModel>(for descriptor: FetchDescriptor<T>, entity: String) throws -> (from: String, whereSQL: SQL, order: String) {
        let root = Fragment.row(entity: entity, key: SQL("t0.\(q(EntityTable.primaryKey))"), alias: "t0")
        var whereSQL = SQL("")
        if let predicate = descriptor.predicate {
            variables[predicate.variable.key] = root
            whereSQL = " WHERE " + (try boolean(predicate.expression))
        }

        var order: [String] = []
        for sort in descriptor.sortBy {
            guard let keyPath = sort.keyPath,
                  let (column, kind) = try sortColumn(keyPath, entity: entity),
                  [.integer, .real, .text, .bool].contains(kind) else {
                throw Untranslatable(reason: "sort by \(String(describing: sort.keyPath))")
            }
            var term = column
            if kind == .text, let comparator = sort.stringComparator {
                if comparator == .localizedStandard { term += " COLLATE sc_localized_standard" }
                else if comparator == .localized { term += " COLLATE sc_localized" }
            }
            order.append(term + (sort.order == .forward ? " ASC" : " DESC"))
        }
        order.append("t0.rowid ASC")
        return ("\(q(entity)) AS t0" + outerJoins, whereSQL, " ORDER BY " + order.joined(separator: ", "))
    }
}

extension SQLQueryBuilder {
    /// The column a sort key path reads, joining through to-one relationships.
    ///
    /// SwiftData sorts in memory by the first descriptor only when a store falls back, so
    /// relationship sorts must run in SQL to keep tie-breaking descriptors working.
    /// Composite key paths cannot be split with public API; their description
    /// (`\Book.author?.name`) is parsed instead, and anything unexpected is untranslatable.
    func sortColumn(_ keyPath: AnyKeyPath, entity: String) throws -> (String, ColumnKind)? {
        let names: [String]
        if let name = PropertyNames.name(of: keyPath) {
            names = [name]
        } else {
            var description = "\(keyPath)"
            guard description.hasPrefix("\\"), let dot = description.firstIndex(of: ".") else { return nil }
            description = String(description[description.index(after: dot)...])
            names = description.replacingOccurrences(of: "?", with: "").replacingOccurrences(of: "!", with: "")
                .split(separator: ".").map(String.init)
        }
        var current = entity
        var alias = "t0"
        for (i, name) in names.enumerated() {
            let table = try table(current)
            if i == names.count - 1 {
                guard let attribute = table.attributes.first(where: { $0.name == name }) else { return nil }
                return ("\(alias).\(q(name))", attribute.kind)
            }
            guard let destination = table.toOne[name] else { return nil }
            alias = self.alias(for: destination, key: SQL("\(alias).\(q(name))"), alias: nil)
            current = destination
        }
        return nil
    }
}

extension Connection {
    /// Registers the functions and collations translated predicates and sorts rely on.
    func registerSwiftStringFunctions() throws {
        func strings(_ args: [Binding?]) -> (String, String)? {
            guard let a = args[0] as? String, let b = args[1] as? String else { return nil }
            return (a, b)
        }
        createFunction("sc_contains", argumentCount: 2, deterministic: true) { args in
            strings(args).map { Int64($0.contains($1) ? 1 : 0) }
        }
        createFunction("sc_localized_contains", argumentCount: 2, deterministic: true) { args in
            strings(args).map { Int64($0.localizedStandardContains($1) ? 1 : 0) }
        }
        createFunction("sc_starts_with", argumentCount: 2, deterministic: true) { args in
            strings(args).map { Int64($0.starts(with: $1) ? 1 : 0) }
        }
        // Not `createCollation`: it reads the operands as C strings, but SQLite passes them
        // with a length and no terminator, which makes comparisons read past the buffer.
        try registerCollation("sc_localized_standard") { a, n, b, m in
            Int32(collationString(a, n).localizedStandardCompare(collationString(b, m)).rawValue)
        }
        try registerCollation("sc_localized") { a, n, b, m in
            Int32(collationString(a, n).localizedCompare(collationString(b, m)).rawValue)
        }
    }

    private func registerCollation(
        _ name: String,
        _ compare: @escaping @convention(c) (UnsafeRawPointer?, Int32, UnsafeRawPointer?, Int32) -> Int32
    ) throws {
        // SQLite's callback has a leading context pointer; the comparison needs none, so the
        // context slot carries the comparison function itself.
        let context = unsafeBitCast(compare, to: UnsafeMutableRawPointer.self)
        let status = sqlite3_create_collation_v2(handle, name, SQLITE_UTF8, context, { context, n, a, m, b in
            let compare = unsafeBitCast(context, to: (@convention(c) (UnsafeRawPointer?, Int32, UnsafeRawPointer?, Int32) -> Int32).self)
            return compare(a, n, b, m)
        }, nil)
        guard status == SQLITE_OK else { throw CipherError.storeCorrupted("could not register collation \(name)") }
    }
}

private func collationString(_ pointer: UnsafeRawPointer?, _ length: Int32) -> String {
    guard let pointer else { return "" }
    return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(length)), as: UTF8.self)
}
